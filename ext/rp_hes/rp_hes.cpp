// rp_hes: HES playback with PSG state snapshots. See rp_hes.h.

#include "rp_hes.h"

#include "Hes_Emu.h"
#include "rp_recorder.h"

#include <string.h>

static_assert(sizeof(rp_hes_snapshot) == 8, "rp_hes_snapshot layout changed");

namespace {

// Hes_Emu recording PSG snapshots (see rp::Recorder).
class Rp_Hes_Emu : public rp::Recorder<Hes_Emu, rp_hes_snapshot> {};

Music_Emu* new_rp_hes_emu() { return new Rp_Hes_Emu; }

// gme_hes_type with our subclass as the emulator.
gme_type_t_ rp_hes_type()
{
	gme_type_t_ type = *gme_hes_type;
	type.new_emu = &new_rp_hes_emu;
	return type;
}

const gme_type_t_ RP_HES_TYPE = rp_hes_type();

void fill_snapshot(Rp_Hes_Emu&, rp_hes_snapshot& snap)
{
	memset(&snap, 0, sizeof snap);
}

} // namespace

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
