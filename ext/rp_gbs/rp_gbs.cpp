// rp_gbs: GBS playback with APU state snapshots. See rp_gbs.h.

#include "rp_gbs.h"

#include "Gbs_Emu.h"
#include "rp_recorder.h"

#include <string.h>
#include <vector>

static_assert(sizeof(rp_gbs_snapshot) == 80, "rp_gbs_snapshot layout changed; update Gbs::Snapshot");

namespace {

// Register-write snapshots closer together than this (timer-driven drivers
// can run at several hundred Hz) fold into one; their triggers accumulate.
// Changes in which voices sound, or how loud, are always recorded.
const long MIN_SNAPSHOTS_PER_SECOND_DIVISOR = 240;
const int TRIGGER_REGS[Gb_Apu::osc_count] = { 4, 9, 14, 19 };
const int NR30 = 10;
const uint64_t UNKNOWN = ~(uint64_t) 0;

// Gbs_Emu recording Game Boy APU snapshots (see rp::Recorder).
class Rp_Gbs_Emu : public rp::Recorder<Gbs_Emu, rp_gbs_snapshot> {
public:
	uint8_t triggers = 0;
	// audible_state_key() of the latest queued snapshot.
	uint64_t last_audible_key = UNKNOWN;

protected:
	void reset_recording() override
	{
		triggers = 0;
		last_audible_key = UNKNOWN;
	}
};

Music_Emu* new_rp_gbs_emu() { return new Rp_Gbs_Emu; }

// gme_gbs_type with our subclass as the emulator.
gme_type_t_ rp_gbs_type()
{
	gme_type_t_ type = *gme_gbs_type;
	type.new_emu = &new_rp_gbs_emu;
	return type;
}

const gme_type_t_ RP_GBS_TYPE = rp_gbs_type();

// Bit i: oscillator i is producing sound. Gb_Apu::run_until's test, plus
// square 1's sweep overflow silencing it.
uint8_t playing_bits(Gb_Apu const& apu)
{
	uint8_t bits = 0;
	for (int i = 0; i < Gb_Apu::osc_count; i++) {
		Gb_Osc const& osc = apu.rp_osc(i);
		bool length_ok = !(osc.regs[4] & Gb_Osc::len_enabled_mask) || osc.length;
		bool silenced = i == 0 && apu.rp_sweep_freq() == 2048;
		if (osc.enabled && osc.volume && length_ok && !silenced)
			bits |= 1 << i;
	}
	return bits;
}

// What is heard, packed into one comparable key: a change means a snapshot
// is due. Bits 0-3: voices sounding; then one byte of volume per voice.
uint64_t audible_state_key(Gb_Apu const& apu)
{
	uint64_t state = playing_bits(apu);
	for (int i = 0; i < Gb_Apu::osc_count; i++)
		state |= (uint64_t) (uint8_t) apu.rp_osc(i).volume << (8 + 8 * i);
	return state;
}

void fill_snapshot(Rp_Gbs_Emu& emu, rp_gbs_snapshot& snap)
{
	memset(&snap, 0, sizeof snap);
	Gb_Apu const& apu = emu.rp_apu();
	memcpy(snap.regs, apu.rp_regs(), sizeof snap.regs);
	for (int i = 0; i < Gb_Apu::osc_count; i++) {
		Gb_Osc const& osc = apu.rp_osc(i);
		bool length_ok = !(osc.regs[4] & Gb_Osc::len_enabled_mask) || osc.length;
		snap.volume[i] = (uint8_t) osc.volume;
		snap.length[i] = (uint16_t) osc.length;
		if (osc.enabled && length_ok)
			snap.enabled |= 1 << i;
	}
	snap.playing = playing_bits(apu);
	snap.sweep_freq = (uint16_t) apu.rp_sweep_freq();
	snap.play_period = (uint32_t) emu.rp_play_period();
	snap.clock_rate = 4194304;
}

// Records the APU's current state as heard from absolute clock `label`.
void push(Rp_Gbs_Emu& emu, int64_t label)
{
	rp_gbs_snapshot snap;
	fill_snapshot(emu, snap);
	snap.triggers = emu.triggers;
	emu.queue(snap, label);
	emu.triggers = 0;
	emu.last_audible_key = audible_state_key(emu.rp_apu());
}

// The APU runs lazily: until something advances it, its state is the one
// the latest write left. So at each hook, a change since the previous one
// came from that write (a trigger, a DAC switched off) and is recorded at
// its time, even when the note it started has already ended by now.
void observe_writes(Rp_Gbs_Emu& emu, long clock)
{
	if (audible_state_key(emu.rp_apu()) != emu.last_audible_key)
		push(emu, emu.wrote ? emu.last_write_clock : emu.absolute_clock(clock));
}

// Advances the APU to `clock` one frame-sequencer step at a time, the only
// moments length counters, envelopes, and sweep act, recording each step
// that changes what is heard. Output is unchanged: register writes run the
// APU to arbitrary times the same way.
void step_to(Rp_Gbs_Emu& emu, long clock)
{
	Gb_Apu const& apu = emu.rp_apu();
	while (apu.rp_next_frame_time() < clock) {
		long step = apu.rp_next_frame_time();
		emu.rp_catch_up(step + 1);
		if (audible_state_key(apu) != emu.last_audible_key)
			push(emu, emu.absolute_clock(step));
	}
}

} // namespace

// Called from the vendored core (rp_gbs_hooks.h). Every Gbs_Emu in this
// library is an Rp_Gbs_Emu: only RP_GBS_TYPE creates emulators.
void rp_gbs_apu_write(Gbs_Emu* base, int reg, int data, long clock)
{
	Rp_Gbs_Emu& emu = *static_cast<Rp_Gbs_Emu*>(base);
	if (!emu.recording)
		return;

	// A driver's writes for one note (NRx1..NRx4) land together, so only a
	// frame-sequencer step due before this write, which would change the
	// state they leave, records it now; the driver call after them does
	// otherwise. (libgme makes a voice sound again at its NRx1 length
	// reload, before the trigger.)
	if (emu.rp_apu().rp_next_frame_time() < clock) {
		observe_writes(emu, clock);
		step_to(emu, clock);
	}
	for (int i = 0; i < Gb_Apu::osc_count; i++) {
		// The wave channel only starts when its DAC (NR30 bit 7) is on.
		if (reg == TRIGGER_REGS[i] && (data & 0x80) && (i != 2 || (emu.rp_apu().rp_regs()[NR30] & 0x80)))
			emu.triggers |= 1 << i;
	}
	emu.last_write_clock = emu.absolute_clock(clock);
	emu.wrote = true;
}

void rp_gbs_driver_call(Gbs_Emu* base, long clock)
{
	Rp_Gbs_Emu& emu = *static_cast<Rp_Gbs_Emu*>(base);
	if (!emu.recording)
		return;

	observe_writes(emu, clock);
	// The registers the previous driver call left, at its last write (when
	// they were heard) rather than this call's start, a driver period later.
	if (emu.wrote && (emu.last_snapshot_clock == rp::NO_CLOCK ||
			emu.last_write_clock - emu.last_snapshot_clock >= 4194304 / MIN_SNAPSHOTS_PER_SECOND_DIVISOR))
		push(emu, emu.last_write_clock);
	step_to(emu, clock);
}

void rp_gbs_frame_end(Gbs_Emu* base, long clock)
{
	Rp_Gbs_Emu& emu = *static_cast<Rp_Gbs_Emu*>(base);
	if (!emu.recording)
		return;

	observe_writes(emu, clock);
	step_to(emu, clock);
}

struct rp_gbs : rp::Player<Rp_Gbs_Emu> {};

extern "C" {

rp_gbs* rp_gbs_open(const void* data, long size, int out_rate)
{
	return rp::open<rp_gbs>(&RP_GBS_TYPE, data, size, out_rate);
}

void rp_gbs_close(rp_gbs* handle) { rp::close(handle); }

int rp_gbs_load_m3u(rp_gbs* handle, const void* data, long size) { return rp::load_m3u(handle, data, size); }

int rp_gbs_start_track(rp_gbs* handle, int track) { return rp::start_track(handle, track); }

void rp_gbs_set_fade(rp_gbs* handle, long start_ms)
{
	if (handle)
		gme_set_fade(handle->emu, (int) start_ms);
}

void rp_gbs_ignore_silence(rp_gbs* handle, int ignore)
{
	if (handle)
		gme_ignore_silence(handle->emu, ignore);
}

int rp_gbs_play(rp_gbs* handle, float* out, long frames) { return rp::play(handle, out, frames); }

int rp_gbs_track_ended(rp_gbs* handle)
{
	return handle ? gme_track_ended(handle->emu) : 1;
}

int rp_gbs_seek(rp_gbs* handle, long ms) { return rp::seek(handle, ms); }

long rp_gbs_tell_ms(rp_gbs* handle)
{
	return handle ? gme_tell(handle->emu) : 0;
}

void rp_gbs_mute_voices(rp_gbs* handle, int mask)
{
	if (handle)
		gme_mute_voices(handle->emu, mask);
}

int rp_gbs_snapshot_size(void)
{
	return (int) sizeof(rp_gbs_snapshot);
}

int rp_gbs_snapshot_count(rp_gbs* handle)
{
	return handle ? (int) handle->emu->snapshots.size() : 0;
}

const rp_gbs_snapshot* rp_gbs_snapshots(rp_gbs* handle)
{
	return handle && !handle->emu->snapshots.empty() ? handle->emu->snapshots.data() : NULL;
}

void rp_gbs_capture_now(rp_gbs* handle) { rp::capture_now(handle, fill_snapshot); }

} // extern "C"
