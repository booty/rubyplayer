// rp_recorder: what every native libgme player shares. An emulator
// subclass that records chip-state snapshots while libgme emulates, and
// maps them from emulator clocks to the output frames they are heard at;
// plus the C API plumbing (open, play, seek, capture) built on it.
//
// A format supplies its snapshot struct (with `frame` and `triggers`
// fields), fills snapshots from its chips, and calls queue() from libgme's
// instrumentation hooks.

#ifndef RP_RECORDER_H
#define RP_RECORDER_H

#include "Music_Emu.h"
#include "gme.h"

#include <stdint.h>
#include <string.h>
#include <vector>

namespace rp {

const int64_t NO_CLOCK = -1;

// Output frame of an emulator event = emulator frame of its clock - lead,
// where lead is how many emulated frames libgme's leading-silence skip
// discarded (Music_Emu restarts emu_time at the skipped-to point; every later
// emulated sample is output in order, so the lead stays fixed until the next
// start_track).
template <class Base, class Snapshot>
class Recorder : public Base {
public:
	bool recording = false;
	// Whether registers were written since the latest queued snapshot.
	bool wrote = false;
	int64_t last_write = NO_CLOCK;
	int64_t last_push = NO_CLOCK;
	// Snapshots handed out by the latest play, seek capture, or start.
	std::vector<Snapshot> snapshots;

	// Emulated frames that libgme's leading-silence skip discarded. Only
	// settled outside emulator calls.
	int64_t lead() const { return frames_played_ - this->rp_emu_time() / 2; }

	// Absolute CPU clock of `clock` within the frame being emulated.
	int64_t absolute(long clock) const { return clock_base_ + clock; }

	int64_t out_frame() const { return this->tell_samples() / 2; }

	// Records `snapshot` as heard from absolute clock `label`.
	void queue(Snapshot const& snapshot, int64_t label)
	{
		pending_.push_back({ label * this->sample_rate() / this->clock_rate(), snapshot });
		wrote = false;
		last_push = label;
	}

	// Moves queued snapshots to the settled list, at the output frames they
	// play at. Call after every libgme call that may emulate.
	void settle()
	{
		int64_t skipped = lead();
		for (Pending const& item : pending_)
			heard_.push_back({ item.emulated_frame - skipped, item.snapshot });
		pending_.clear();
	}

	// Hands out the snapshots not yet returned, relative to out_start. The
	// leading-silence search emulates before output begins; the newest
	// snapshot from then is the state the first heard note starts from, so it
	// becomes frame 0 (carrying older ones' triggers) and older ones go.
	void publish(int64_t out_start)
	{
		snapshots.clear();
		bool clamped = false;
		for (size_t i = returned_; i < heard_.size(); i++) {
			int64_t frame = heard_[i].frame - out_start;
			decltype(Snapshot().triggers) carried = 0;
			if (frame < 0 && clamped) {
				carried = snapshots.back().triggers;
				snapshots.pop_back();
			}
			clamped = frame < 0;
			snapshots.push_back(heard_[i].snapshot);
			snapshots.back().frame = clamped ? 0 : (int32_t) frame;
			snapshots.back().triggers |= carried;
		}
		returned_ = heard_.size();
		prune(out_frame());
	}

	// Hands out what is heard from the output position on: the state heard
	// there at frame 0, then every later snapshot. False when none is known.
	bool publish_from_position()
	{
		int64_t position = out_frame();
		size_t at = newest_at_or_before(position);
		if (at == heard_.size())
			return false;

		snapshots.clear();
		for (size_t i = at; i < heard_.size(); i++) {
			snapshots.push_back(heard_[i].snapshot);
			snapshots.back().frame = i == at ? 0 : (int32_t) (heard_[i].frame - position);
		}
		returned_ = heard_.size();
		prune(position);
		return true;
	}

protected:
	// The format's own recording state, cleared on every track start.
	virtual void reset_recording() {}

	blargg_err_t start_track_(int track) override
	{
		clock_base_ = 0;
		frames_played_ = 0;
		wrote = false;
		last_write = NO_CLOCK;
		last_push = NO_CLOCK;
		pending_.clear();
		heard_.clear();
		returned_ = 0;
		reset_recording();
		return Base::start_track_(track);
	}

	blargg_err_t run_clocks(blip_time_t& duration, int msec) override
	{
		blargg_err_t err = Base::run_clocks(duration, msec);
		clock_base_ += duration;
		return err;
	}

	blargg_err_t play_(long count, typename Base::sample_t* out) override
	{
		frames_played_ += count / 2;
		return Base::play_(count, out);
	}

private:
	// A snapshot recorded during emulation, before its output frame is known.
	struct Pending {
		int64_t emulated_frame;
		Snapshot snapshot;
	};

	// A snapshot at its absolute output frame (out_time / 2 when heard).
	struct Heard {
		int64_t frame;
		Snapshot snapshot;
	};

	int64_t clock_base_ = 0;   // absolute clock at the start of the current frame
	int64_t frames_played_ = 0;
	std::vector<Pending> pending_;
	// Settled snapshots, oldest first, kept from the one heard at the output
	// position onwards: libgme emulates ahead of output (silence lookahead),
	// and a seek within that buffered audio emulates nothing.
	std::vector<Heard> heard_;
	// heard_[0, returned_) were already handed out.
	size_t returned_ = 0;

	// Index of the newest snapshot heard at or before `frame`, or
	// heard_.size() when there is none.
	size_t newest_at_or_before(int64_t frame) const
	{
		size_t found = heard_.size();
		for (size_t i = 0; i < heard_.size() && heard_[i].frame <= frame; i++)
			found = i;
		return found;
	}

	// Drops snapshots superseded before `position`: output never goes back
	// without start_track, which clears them all.
	void prune(int64_t position)
	{
		size_t keep = newest_at_or_before(position);
		if (keep == heard_.size() || keep == 0)
			return;
		heard_.erase(heard_.begin(), heard_.begin() + (long) keep);
		returned_ = returned_ > keep ? returned_ - keep : 0;
	}
};

// The C API's handle (each format's opaque struct derives from it): the
// emulator plus libgme's int16 output buffer.
template <class Emu>
struct Player {
	typedef Emu emu_type;
	Emu* emu = NULL;
	std::vector<short> samples;
};

// `type` is the format's gme type with new_emu returning the Handle's
// emulator, so gme_new_emu builds it exactly as libgme builds the stock one
// (Effects_Buffer, sample rate, and all).
template <class Handle>
Handle* open(gme_type_t type, const void* data, long size, int out_rate)
{
	if (!data || size <= 0)
		return NULL;

	Music_Emu* music = gme_new_emu(type, out_rate);
	if (!music)
		return NULL;
	if (gme_load_data(music, data, size)) {
		gme_delete(music);
		return NULL;
	}
	Handle* handle = new Handle;
	handle->emu = static_cast<typename Handle::emu_type*>(music);
	return handle;
}

template <class Emu>
int load_m3u(Player<Emu>* player, const void* data, long size)
{
	if (!player || !data || size <= 0)
		return 0;
	return gme_load_m3u_data(player->emu, data, size) == NULL;
}

template <class Handle>
void close(Handle* handle)
{
	if (!handle)
		return;
	gme_delete(handle->emu);
	delete handle;
}

template <class Emu>
int start_track(Player<Emu>* player, int track)
{
	if (!player)
		return 0;
	Emu& emu = *player->emu;
	emu.snapshots.clear();
	// Recorded so the first play can show the state its first note starts
	// from, which libgme emulates while skipping leading silence.
	emu.recording = true;
	gme_err_t err = gme_start_track(&emu, track);
	emu.recording = false;
	emu.settle();
	return err == NULL;
}

// Fills `frames` stereo float frames; 1 on success.
template <class Emu>
int play(Player<Emu>* player, float* out, long frames)
{
	if (!player || frames <= 0)
		return 0;

	Emu& emu = *player->emu;
	int64_t out_start = emu.out_frame();
	long count = frames * 2;
	if ((long) player->samples.size() < count)
		player->samples.resize(count);
	emu.recording = true;
	gme_err_t err = gme_play(&emu, (int) count, player->samples.data());
	emu.recording = false;
	emu.settle();
	emu.publish(out_start);

	// Same scale as Backends::Gme::Handle#read (AudioFormat::GME_INT16_SCALE).
	for (long i = 0; i < count; i++)
		out[i] = player->samples[i] / 32768.0f;
	return err == NULL;
}

template <class Emu>
int seek(Player<Emu>* player, long ms)
{
	if (!player)
		return 0;
	Emu& emu = *player->emu;
	emu.snapshots.clear();
	// Recorded so capture_now can show the state heard at the target.
	emu.recording = true;
	gme_err_t err = gme_seek(&emu, (int) ms);
	emu.recording = false;
	emu.settle();
	return err == NULL;
}

// Leaves the snapshots heard from the current position on, or one of the
// emulator's current state (from `fill`) when none was recorded.
template <class Emu, class Fill>
void capture_now(Player<Emu>* player, Fill fill)
{
	if (!player)
		return;
	Emu& emu = *player->emu;
	if (emu.publish_from_position())
		return;

	emu.snapshots.resize(1);
	fill(emu, emu.snapshots[0]);
}

} // namespace rp

#endif
