// rp_gbs: GBS playback with APU state snapshots. See rp_gbs.h.

#include "rp_gbs.h"

#include "Gbs_Emu.h"
#include "gme.h"

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
const int64_t NO_CLOCK = -1;
const uint64_t UNKNOWN = ~(uint64_t) 0;

// A snapshot recorded during emulation, before its output frame is known.
struct Pending {
	int64_t emulated_frame;
	rp_gbs_snapshot snapshot;
};

// A snapshot at its absolute output frame (out_time / 2 when heard).
struct Heard {
	int64_t frame;
	rp_gbs_snapshot snapshot;
};

// Gbs_Emu plus the bookkeeping that maps emulator clocks to output frames.
//
// Output frame of an APU event = emulator frame of its clock - lead, where
// lead is how many emulated frames libgme's leading-silence skip discarded
// (Music_Emu restarts emu_time at the skipped-to point; every later emulated
// sample is output in order, so the lead stays fixed until the next
// start_track).
class Rp_Gbs_Emu : public Gbs_Emu {
public:
	bool recording = false;
	uint8_t triggers = 0;
	// Whether registers were written since the latest pending snapshot.
	bool wrote = false;
	int64_t last_write = NO_CLOCK;
	int64_t last_push = NO_CLOCK;
	// audible() of the latest pending snapshot.
	uint64_t last_audible = UNKNOWN;
	std::vector<Pending> pending;
	// Settled snapshots, oldest first, kept from the one heard at the
	// output position onwards: libgme emulates ahead of output (silence
	// lookahead), and a seek within that buffered audio emulates nothing.
	std::vector<Heard> heard;
	// heard[0, returned) were already handed out.
	size_t returned = 0;
	std::vector<rp_gbs_snapshot> snapshots;

	// Emulated frames that libgme's leading-silence skip discarded. Only
	// settled outside emulator calls.
	int64_t lead() const { return frames_played_ - rp_emu_time() / 2; }

	// Absolute CPU clock of `clock` within the frame being emulated.
	int64_t absolute(long clock) const { return clock_base + clock; }

	int64_t emulated_frame(int64_t absolute_clock) const
	{
		return absolute_clock * sample_rate() / clock_rate();
	}

	int64_t out_frame() const { return tell_samples() / 2; }

	// Moves pending snapshots to `heard`, at the output frames they play at.
	void settle()
	{
		int64_t skipped = lead();
		for (Pending const& item : pending)
			heard.push_back({ item.emulated_frame - skipped, item.snapshot });
		pending.clear();
	}

	// Hands out the snapshots not yet returned, relative to out_start. The
	// leading-silence search emulates before output begins; the newest
	// snapshot from then is the state the first heard note starts from, so it
	// becomes frame 0 (carrying older ones' triggers) and older ones go.
	void publish(int64_t out_start)
	{
		snapshots.clear();
		bool clamped = false;
		for (size_t i = returned; i < heard.size(); i++) {
			int64_t frame = heard[i].frame - out_start;
			uint8_t carried = 0;
			if (frame < 0 && clamped) {
				carried = snapshots.back().triggers;
				snapshots.pop_back();
			}
			clamped = frame < 0;
			snapshots.push_back(heard[i].snapshot);
			snapshots.back().frame = clamped ? 0 : (int32_t) frame;
			snapshots.back().triggers |= carried;
		}
		returned = heard.size();
		prune(out_frame());
	}

	// Hands out what is heard from the output position on: the state heard
	// there at frame 0, then every later snapshot. False when none is known.
	bool publish_from_position()
	{
		int64_t position = out_frame();
		size_t at = newest_at_or_before(position);
		if (at == heard.size())
			return false;

		snapshots.clear();
		for (size_t i = at; i < heard.size(); i++) {
			snapshots.push_back(heard[i].snapshot);
			snapshots.back().frame = i == at ? 0 : (int32_t) (heard[i].frame - position);
		}
		returned = heard.size();
		prune(position);
		return true;
	}

protected:
	blargg_err_t start_track_(int track) override
	{
		clock_base = 0;
		frames_played_ = 0;
		triggers = 0;
		wrote = false;
		last_write = NO_CLOCK;
		last_push = NO_CLOCK;
		last_audible = UNKNOWN;
		pending.clear();
		heard.clear();
		returned = 0;
		return Gbs_Emu::start_track_(track);
	}

	blargg_err_t run_clocks(blip_time_t& duration, int msec) override
	{
		blargg_err_t err = Gbs_Emu::run_clocks(duration, msec);
		clock_base += duration;
		return err;
	}

	blargg_err_t play_(long count, sample_t* out) override
	{
		frames_played_ += count / 2;
		return Gbs_Emu::play_(count, out);
	}

private:
	int64_t clock_base = 0;   // absolute clock at the start of the current frame
	int64_t frames_played_ = 0;

	// Index of the newest snapshot heard at or before `frame`, or
	// heard.size() when there is none.
	size_t newest_at_or_before(int64_t frame) const
	{
		size_t found = heard.size();
		for (size_t i = 0; i < heard.size() && heard[i].frame <= frame; i++)
			found = i;
		return found;
	}

	// Drops snapshots superseded before `position`: output never goes back
	// without start_track, which clears them all.
	void prune(int64_t position)
	{
		size_t keep = newest_at_or_before(position);
		if (keep == heard.size() || keep == 0)
			return;
		heard.erase(heard.begin(), heard.begin() + (long) keep);
		returned = returned > keep ? returned - keep : 0;
	}
};

Music_Emu* new_rp_gbs_emu() { return new Rp_Gbs_Emu; }

// gme_gbs_type with our subclass as the emulator, so gme_new_emu builds it
// exactly as libgme builds Gbs_Emu (Effects_Buffer, sample rate, and all).
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

// What is heard: which voices sound, and how loud.
uint64_t audible(Gb_Apu const& apu)
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
	Pending item;
	fill_snapshot(emu, item.snapshot);
	item.snapshot.triggers = emu.triggers;
	item.emulated_frame = emu.emulated_frame(label);
	emu.pending.push_back(item);
	emu.triggers = 0;
	emu.wrote = false;
	emu.last_push = label;
	emu.last_audible = audible(emu.rp_apu());
}

// The APU runs lazily: until something advances it, its state is the one
// the latest write left. So at each hook, a change since the previous one
// came from that write (a trigger, a DAC switched off) and is recorded at
// its time, even when the note it started has already ended by now.
void observe_writes(Rp_Gbs_Emu& emu, long clock)
{
	if (audible(emu.rp_apu()) != emu.last_audible)
		push(emu, emu.wrote ? emu.last_write : emu.absolute(clock));
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
		if (audible(apu) != emu.last_audible)
			push(emu, emu.absolute(step));
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
	emu.last_write = emu.absolute(clock);
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
	if (emu.wrote && (emu.last_push == NO_CLOCK ||
			emu.last_write - emu.last_push >= 4194304 / MIN_SNAPSHOTS_PER_SECOND_DIVISOR))
		push(emu, emu.last_write);
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

struct rp_gbs {
	Rp_Gbs_Emu* emu;
	std::vector<short> samples;
};

extern "C" {

rp_gbs* rp_gbs_open(const void* data, long size, int out_rate)
{
	if (!data || size <= 0)
		return NULL;

	Music_Emu* music = gme_new_emu(&RP_GBS_TYPE, out_rate);
	if (!music)
		return NULL;
	if (gme_load_data(music, data, size)) {
		gme_delete(music);
		return NULL;
	}
	rp_gbs* handle = new rp_gbs;
	handle->emu = static_cast<Rp_Gbs_Emu*>(music);
	return handle;
}

void rp_gbs_close(rp_gbs* handle)
{
	if (!handle)
		return;
	gme_delete(handle->emu);
	delete handle;
}

int rp_gbs_load_m3u(rp_gbs* handle, const void* data, long size)
{
	if (!handle || !data || size <= 0)
		return 0;
	return gme_load_m3u_data(handle->emu, data, size) == NULL;
}

int rp_gbs_start_track(rp_gbs* handle, int track)
{
	if (!handle)
		return 0;
	Rp_Gbs_Emu& emu = *handle->emu;
	emu.snapshots.clear();
	// Recorded so the first play can show the state its first note starts
	// from, which libgme emulates while skipping leading silence.
	emu.recording = true;
	gme_err_t err = gme_start_track(&emu, track);
	emu.recording = false;
	emu.settle();
	return err == NULL;
}

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

int rp_gbs_play(rp_gbs* handle, float* out, long frames)
{
	if (!handle || frames <= 0)
		return 0;

	Rp_Gbs_Emu& emu = *handle->emu;
	int64_t out_start = emu.tell_samples() / 2;

	long count = frames * 2;
	if ((long) handle->samples.size() < count)
		handle->samples.resize(count);
	emu.recording = true;
	gme_err_t err = gme_play(&emu, (int) count, handle->samples.data());
	emu.recording = false;
	emu.settle();
	emu.publish(out_start);

	// Same scale as Backends::Gme::Handle#read (AudioFormat::GME_INT16_SCALE).
	for (long i = 0; i < count; i++)
		out[i] = handle->samples[i] / 32768.0f;
	return err == NULL;
}

int rp_gbs_track_ended(rp_gbs* handle)
{
	return handle ? gme_track_ended(handle->emu) : 1;
}

int rp_gbs_seek(rp_gbs* handle, long ms)
{
	if (!handle)
		return 0;
	Rp_Gbs_Emu& emu = *handle->emu;
	emu.snapshots.clear();
	// Recorded so capture_now can show the state heard at the target.
	emu.recording = true;
	gme_err_t err = gme_seek(&emu, (int) ms);
	emu.recording = false;
	emu.settle();
	return err == NULL;
}

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

void rp_gbs_capture_now(rp_gbs* handle)
{
	if (!handle)
		return;
	Rp_Gbs_Emu& emu = *handle->emu;
	if (emu.publish_from_position())
		return;

	emu.snapshots.clear();
	rp_gbs_snapshot snap;
	fill_snapshot(emu, snap);
	emu.snapshots.push_back(snap);
}

} // extern "C"
