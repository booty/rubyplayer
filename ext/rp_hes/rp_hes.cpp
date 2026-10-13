// rp_hes: HES playback with PSG state snapshots. See rp_hes.h.

#include "rp_hes.h"

#include "Hes_Emu.h"
#include "rp_recorder.h"

#include <string.h>

static_assert(sizeof(rp_hes_snapshot) == 268, "rp_hes_snapshot layout changed; update Hes::Snapshot");

namespace {

// Writes waiting longer than this are recorded even without a driver call:
// libgme's driver hook fires only near 60 Hz, and DAC streams write
// thousands of times a second.
const long MAX_SNAPSHOTS_PER_SECOND = 240;
// PSG register offsets from $800.
const int CONTROL_REG = 4;
const int BALANCE_REG = 5;
const int NOISE_REG = 7;
const int KEY_ON = 0x80;
const int DIRECT_DAC = 0x40;
const int NOISE_ON = 0x80;
// Hes_Osc::run_until plays a wave only when period * 2 >= 14.
const int MIN_AUDIBLE_WAVE_PERIOD = 7;
// Per voice in an audible state key: sounding, keyed, direct DAC, noise.
const int KEY_BITS_PER_VOICE = 4;
const uint32_t VOICE_KEY_MASK = 0xF;
const uint32_t UNKNOWN = ~(uint32_t) 0;

// Hes_Emu recording PSG snapshots (see rp::Recorder).
class Rp_Hes_Emu : public rp::Recorder<Hes_Emu, rp_hes_snapshot> {
public:
	uint8_t triggers = 0;
	// audible_state_key() of the latest queued snapshot.
	uint32_t last_audible_key = UNKNOWN;
	// Clock of the oldest write not yet in a snapshot.
	int64_t first_pending_write_clock = rp::NO_CLOCK;

	// Classic_Emu keeps its clock rate protected.
	long cpu_clock_hz() const { return clock_rate(); }

protected:
	void reset_recording() override
	{
		triggers = 0;
		last_audible_key = UNKNOWN;
		first_pending_write_clock = rp::NO_CLOCK;
	}
};

Music_Emu* new_rp_hes_emu() { return new Rp_Hes_Emu; }

// gme_hes_type with our subclass as the emulator.
gme_type_t_ rp_hes_type()
{
	gme_type_t_ type = *gme_hes_type;
	type.new_emu = &new_rp_hes_emu;
	return type;
}

const gme_type_t_ RP_HES_TYPE = rp_hes_type();

// Whether the voice produces sound, as Hes_Osc::run_until decides, but
// regardless of muting (a muted voice still plays its notes).
bool sounding(Hes_Osc const& osc)
{
	if (!(osc.control & KEY_ON) || !(osc.volume [0] | osc.volume [1]))
		return false;
	return (osc.noise & NOISE_ON) || (osc.control & DIRECT_DAC) || osc.period >= MIN_AUDIBLE_WAVE_PERIOD;
}

uint32_t voice_key(Hes_Apu const& apu, int voice)
{
	Hes_Osc const& osc = apu.rp_osc(voice);
	return (uint32_t) sounding(osc) | (osc.control & KEY_ON ? 2 : 0) | (osc.control & DIRECT_DAC ? 4 : 0) |
		(osc.noise & NOISE_ON ? 8 : 0);
}

// What is heard, packed into one comparable key: a change means a snapshot
// is due. Volume, pitch, and balance changes are left to driver calls.
uint32_t audible_state_key(Hes_Apu const& apu)
{
	uint32_t key = 0;
	for (int i = 0; i < Hes_Apu::osc_count; i++)
		key |= voice_key(apu, i) << (KEY_BITS_PER_VOICE * i);
	return key;
}

void fill_snapshot(Rp_Hes_Emu& emu, rp_hes_snapshot& snap)
{
	memset(&snap, 0, sizeof snap);
	Hes_Apu const& apu = emu.rp_apu();
	for (int i = 0; i < Hes_Apu::osc_count; i++) {
		Hes_Osc const& osc = apu.rp_osc(i);
		if (sounding(osc))
			snap.playing |= 1 << i;
		snap.period[i] = (uint16_t) osc.period;
		snap.control[i] = osc.control;
		snap.balance[i] = osc.balance;
		snap.noise[i] = osc.noise;
		// Outside direct-DAC mode, dac is the oscillator's running output,
		// which libgme stops updating while voices are muted (as when seeking
		// skips ahead), so it would differ between seeking and playing.
		snap.dac[i] = osc.control & DIRECT_DAC ? osc.dac : 0;
		memcpy(snap.wave[i], osc.wave, sizeof snap.wave[i]);
		snap.output_left[i] = osc.volume [0];
		snap.output_right[i] = osc.volume [1];
	}
	snap.master_balance = (uint8_t) apu.rp_balance();
	snap.selected_channel = (uint8_t) apu.rp_latch();
	snap.vblank_period_cycles = (uint32_t) emu.rp_play_period();
	snap.cpu_clock_hz = (uint32_t) emu.cpu_clock_hz();
}

// Records the PSG's current state as heard from absolute clock `label`.
void push(Rp_Hes_Emu& emu, int64_t label)
{
	rp_hes_snapshot snap;
	fill_snapshot(emu, snap);
	snap.triggers = emu.triggers;
	emu.queue(snap, label);
	emu.triggers = 0;
	emu.last_audible_key = audible_state_key(emu.rp_apu());
}

} // namespace

// Called from the vendored core (rp_hes_hooks.h) before each PSG write.
// Every Hes_Emu in this library is an Rp_Hes_Emu: only RP_HES_TYPE creates
// emulators.
//
// A driver writes a note's key on, volume, and period together, so they
// normally land in one snapshot at the next driver call. Two kinds of write
// record the pending state first: one that would overwrite a voice's
// unrecorded key or mode change (a note shorter than a driver call), and any
// write once the pending ones are 1/240 s old.
void rp_hes_apu_write(Hes_Emu* base, int reg, int data, long clock)
{
	Rp_Hes_Emu& emu = *static_cast<Rp_Hes_Emu*>(base);
	if (!emu.recording)
		return;

	Hes_Apu const& apu = emu.rp_apu();
	int voice = apu.rp_latch();
	bool voice_write = voice < Hes_Apu::osc_count;
	int64_t now = emu.absolute_clock(clock);
	if (emu.wrote) {
		bool changes_key = reg == CONTROL_REG || reg == BALANCE_REG || reg == NOISE_REG;
		bool overwrites_change = voice_write && changes_key &&
			voice_key(apu, voice) != (emu.last_audible_key >> (KEY_BITS_PER_VOICE * voice) & VOICE_KEY_MASK);
		bool stale = now - emu.first_pending_write_clock >= emu.cpu_clock_hz() / MAX_SNAPSHOTS_PER_SECOND;
		if (overwrites_change || stale)
			push(emu, emu.last_write_clock);
	}
	if (voice_write && reg == CONTROL_REG && (data & KEY_ON) && !(apu.rp_osc(voice).control & KEY_ON))
		emu.triggers |= 1 << voice;
	if (!emu.wrote)
		emu.first_pending_write_clock = now;
	emu.last_write_clock = now;
	emu.wrote = true;
}

// The registers the previous driver call left, at its last write (when
// they were heard) rather than this call's start, a driver period later.
// Within 1/240 s of the previous record only a key or mode change is
// recorded now; other writes wait, so a DAC stream's records stay at 240 Hz.
void rp_hes_driver_call(Hes_Emu* base, long)
{
	Rp_Hes_Emu& emu = *static_cast<Rp_Hes_Emu*>(base);
	if (!emu.recording || !emu.wrote)
		return;

	bool key_changed = audible_state_key(emu.rp_apu()) != emu.last_audible_key;
	bool due = emu.last_snapshot_clock == rp::NO_CLOCK ||
		emu.last_write_clock - emu.last_snapshot_clock >= emu.cpu_clock_hz() / MAX_SNAPSHOTS_PER_SECOND;
	if (key_changed || due)
		push(emu, emu.last_write_clock);
}

struct rp_hes : rp::Player<Rp_Hes_Emu> {};

extern "C" {

rp_hes* rp_hes_open(const void* data, long data_size_bytes, int output_rate_hz)
{
	return rp::open<rp_hes>(&RP_HES_TYPE, data, data_size_bytes, output_rate_hz);
}

void rp_hes_close(rp_hes* handle) { rp::close(handle); }

int rp_hes_load_m3u(rp_hes* handle, const void* data, long data_size_bytes) { return rp::load_m3u(handle, data, data_size_bytes); }

int rp_hes_start_track(rp_hes* handle, int track) { return rp::start_track(handle, track); }

void rp_hes_set_fade(rp_hes* handle, long start_ms)
{
	if (handle)
		gme_set_fade(handle->emu, (int) start_ms);
}

void rp_hes_ignore_silence(rp_hes* handle, int ignore)
{
	if (handle)
		gme_ignore_silence(handle->emu, ignore);
}

int rp_hes_play(rp_hes* handle, float* out, long frames) { return rp::play(handle, out, frames); }

int rp_hes_track_ended(rp_hes* handle)
{
	return handle ? gme_track_ended(handle->emu) : 1;
}

int rp_hes_seek(rp_hes* handle, long ms) { return rp::seek(handle, ms); }

long rp_hes_tell_ms(rp_hes* handle)
{
	return handle ? gme_tell(handle->emu) : 0;
}

void rp_hes_mute_voices(rp_hes* handle, int mask)
{
	if (handle)
		gme_mute_voices(handle->emu, mask);
}

int rp_hes_snapshot_size(void)
{
	return (int) sizeof(rp_hes_snapshot);
}

int rp_hes_snapshot_count(rp_hes* handle)
{
	return handle ? (int) handle->emu->snapshots.size() : 0;
}

const rp_hes_snapshot* rp_hes_snapshots(rp_hes* handle)
{
	return handle && !handle->emu->snapshots.empty() ? handle->emu->snapshots.data() : NULL;
}

void rp_hes_capture_now(rp_hes* handle) { rp::capture_now(handle, fill_snapshot); }

} // extern "C"
