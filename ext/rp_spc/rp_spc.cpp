// rp_spc: libgme-equivalent SPC playback on the vendored snes_spc core.
//
// The control flow below is a port of libgme 0.6.5's Spc_Emu (emulator,
// filter, resampler wiring) and Music_Emu (play/skip/seek/fade/silence),
// kept structurally identical on purpose: parity tests compare our output
// with libgme's sample for sample, and libgme's quirks (fade decided per play
// call, silence runs emitted as exact zeros during fades, the first sample of
// a block ignored by the silence scan) all change samples. Change behavior
// here only together with test/snes_spc_parity_test.rb.

#include "rp_spc.h"

#include "Fir_Resampler.h"
#include "Snes_Spc.h"
#include "Spc_Filter.h"

#include <climits>
#include <cstring>
#include <new>
#include <vector>

namespace {

typedef short sample_t;

const int native_rate = Snes_Spc::sample_rate;  // 32000
const int out_channels = 2;
const long buf_size = 2048;                       // Music_Emu::buf_size, in samples
const int silence_max = 6;                        // seconds
const int silence_threshold = 0x10;
const long fade_block_size = 512;
const int fade_shift = 8;                         // fade ends at gain 1 / (1 << fade_shift)
const int max_initial_silence = 2;                // seconds
const int silence_lookahead = 3;
const double spc_gain = 1.4;                      // Spc_Emu constructor
const double resampler_rolloff = 0.9965;          // Spc_Emu::set_sample_rate_
const int resampler_latency = 64;                 // Spc_Emu::skip_
const int voice_count = Snes_Spc::voice_count;
const int dsp_register_count = 128;

static_assert(sizeof(rp_spc_snapshot) == 176, "rp_spc_snapshot layout is part of the Ruby ABI");

}  // namespace

struct rp_spc {
	Snes_Spc apu;
	SPC_Filter filter;
	Fir_Resampler<24> resampler;
	std::vector<unsigned char> file;
	std::vector<sample_t> buf;      // Music_Emu silence lookahead buffer
	std::vector<sample_t> scratch;  // int16 output before float conversion
	long sample_rate;
	bool resample;
	bool ignore_silence;
	// While the user has voices muted, silence is not the music ending:
	// detection pauses (like ignore_silence, but without restarting).
	bool silence_detection_paused;
	int mute_mask;
	// User fade survives restarts (backward seeks); libgme would instead fall
	// back to Spc_Emu's (length, 50 ms) default after a restart.
	long user_fade_start_ms;
	long user_fade_length_ms;

	std::vector<rp_spc_snapshot> snapshots;
	// Snapshot timing. "output samples" are interleaved samples at the output
	// rate, the unit of out_time/emu_time; snapshot frames are output frames.
	long call_origin_output_samples;  // out_time when the current rp_spc_play began
	long capture_base_output_samples; // output position the next native block feeds
	int previous_env_mode[8];
	int previous_srcn[8];

	long out_time;
	long emu_time;
	long silence_time;
	long silence_count;
	long buf_remain;
	long fade_start;
	int fade_step;
	bool emu_track_ended;
	bool track_ended;
};

namespace {

long msec_to_samples(rp_spc const* s, long msec)
{
	long sec = msec / 1000;
	msec -= sec * 1000;
	return (sec * s->sample_rate + msec * s->sample_rate / 1000) * out_channels;
}

void apply_fade(rp_spc* s, long start_msec, long length_msec)
{
	long step = s->sample_rate * length_msec / (fade_block_size * fade_shift * 1000 / out_channels);
	s->fade_step = (int) (step > 1 ? step : 1);
	s->fade_start = msec_to_samples(s, start_msec);
}

void clear_track_vars(rp_spc* s)
{
	s->out_time = 0;
	s->emu_time = 0;
	s->emu_track_ended = true;
	s->track_ended = true;
	s->fade_start = INT_MAX / 2 + 1;
	s->fade_step = 1;
	s->silence_time = 0;
	s->silence_count = 0;
	s->buf_remain = 0;
}

void end_track_if_error(rp_spc* s, blargg_err_t err)
{
	if (err)
		s->emu_track_ended = true;
}

void capture_snapshot(rp_spc* s, long ahead_native_samples);

// Spc_Emu::play_and_filter, plus one snapshot per emulator call. Snapshots
// cannot be denser without changing the audio: Snes_Spc lets the DSP run
// ahead of the CPU at call boundaries, so splitting a call shifts what driver
// code reads back from the DSP (it changed last-battle.spc by up to 5175 LSB).
// With resampling, libgme emulates ~50 ms per call. `buffered` is native
// input already waiting in the resampler ahead of capture_base_output_samples.
blargg_err_t play_and_filter(rp_spc* s, long count, sample_t* out, long buffered)
{
	blargg_err_t err = s->apu.play((int) count, out);
	if (err)
		return err;
	s->filter.run(out, (int) count);
	capture_snapshot(s, buffered + count);
	return 0;
}

// Spc_Emu::play_. `position` is the output sample position of out[0].
blargg_err_t play_raw(rp_spc* s, long count, sample_t* out, long output_sample_position)
{
	if (!s->resample) {
		s->capture_base_output_samples = output_sample_position;
		return play_and_filter(s, count, out, 0);
	}

	long remain = count;
	while (remain > 0) {
		remain -= s->resampler.read(&out[count - remain], (int) remain);
		if (remain > 0) {
			long n = s->resampler.max_write();
			s->capture_base_output_samples = output_sample_position + (count - remain);
			blargg_err_t err = play_and_filter(s, n, s->resampler.buffer(), s->resampler.written());
			if (err)
				return err;
			s->resampler.write(n);
		}
	}
	return 0;
}

// Spc_Emu::skip_
blargg_err_t skip_raw(rp_spc* s, long count)
{
	if (s->resample) {
		count = long(count * s->resampler.ratio()) & ~1;
		count -= s->resampler.skip_input(count);
	}
	if (count > 0) {
		blargg_err_t err = s->apu.skip((int) count);
		if (err)
			return err;
		s->filter.clear();
	}
	// Eliminates a pop from the resampler.
	sample_t discard[resampler_latency];
	return play_raw(s, resampler_latency, discard, s->emu_time);
}

// Records DSP state tagged with the output frame (relative to the current
// rp_spc_play call) at which it will be heard. `ahead` is how many native
// samples the emulator has produced beyond capture_base_output_samples.
void capture_snapshot(rp_spc* s, long ahead_native_samples)
{
	double ahead_output_samples = s->resample ? ahead_native_samples / s->resampler.ratio()
	                                          : (double) ahead_native_samples;
	long frame = (long) ((s->capture_base_output_samples + ahead_output_samples -
	                      s->call_origin_output_samples) / out_channels);

	rp_spc_snapshot snap;
	memset(&snap, 0, sizeof snap);
	snap.frame = (uint32_t) (frame > 0 ? frame : 0);
	Spc_Dsp const& dsp = s->apu.rp_dsp();
	for (int i = 0; i < dsp_register_count; i++)
		snap.regs[i] = (uint8_t) dsp.read(i);
	for (int v = 0; v < voice_count; v++) {
		int mode = dsp.rp_voice_env_mode(v);
		int srcn = snap.regs[v * 0x10 + 4];
		snap.env[v] = (uint16_t) dsp.rp_voice_env(v);
		snap.env_mode[v] = (uint8_t) mode;
		snap.brr_addr[v] = (uint16_t) dsp.rp_voice_brr_addr(v);
		// Snapshots are ~50 ms apart, so a short attack can fall between two.
		// Also count leaving release, or switching samples, as a new note.
		int previous = s->previous_env_mode[v];
		bool attacked = mode == Spc_Dsp::env_attack && previous != Spc_Dsp::env_attack;
		bool released_to_sounding = previous == Spc_Dsp::env_release && mode != Spc_Dsp::env_release;
		bool new_sample = mode != Spc_Dsp::env_release && srcn != s->previous_srcn[v];
		if (attacked || released_to_sounding || new_sample)
			snap.attack_edges |= (uint8_t) (1 << v);
		s->previous_env_mode[v] = mode;
		s->previous_srcn[v] = srcn;
	}
	s->snapshots.push_back(snap);
}

// Music_Emu::emu_play
void emu_play(rp_spc* s, long count, sample_t* out)
{
	long output_sample_position = s->emu_time;
	s->emu_time += count;
	if (!s->emu_track_ended)
		end_track_if_error(s, play_raw(s, count, out, output_sample_position));
	else
		memset(out, 0, count * sizeof *out);
}

// Music_Emu's count_silence: trailing silent samples; begin[0] is a sentinel.
long count_silence(sample_t* begin, long size)
{
	sample_t first = *begin;
	*begin = silence_threshold;
	sample_t* p = begin + size;
	while ((unsigned) (*--p + silence_threshold / 2) <= (unsigned) silence_threshold) { }
	*begin = first;
	return size - (p - begin);
}

// Music_Emu::fill_buf
void fill_buf(rp_spc* s)
{
	if (!s->emu_track_ended) {
		emu_play(s, buf_size, s->buf.data());
		long silence = count_silence(s->buf.data(), buf_size);
		if (silence < buf_size) {
			s->silence_time = s->emu_time - silence;
			s->buf_remain = buf_size;
			return;
		}
	}
	s->silence_count += buf_size;
}

int int_log(int x, int step, int unit)
{
	int shift = x / step;
	int fraction = (x - shift * step) * unit / step;
	return ((unit - fraction) + (fraction >> 1)) >> shift;
}

// Music_Emu::handle_fade
void handle_fade(rp_spc* s, long out_count, sample_t* out)
{
	for (long i = 0; i < out_count; i += fade_block_size) {
		int const shift = 14;
		int const unit = 1 << shift;
		int gain = int_log((int) ((s->out_time + i - s->fade_start) / fade_block_size), s->fade_step, unit);
		if (gain < (unit >> fade_shift))
			s->track_ended = s->emu_track_ended = true;

		sample_t* io = &out[i];
		for (long count = (fade_block_size < out_count - i ? fade_block_size : out_count - i); count; --count) {
			*io = sample_t((*io * gain) >> shift);
			++io;
		}
	}
}

// Spc_Emu::start_track_ wrapped in Music_Emu::start_track
blargg_err_t start_track(rp_spc* s)
{
	clear_track_vars(s);
	s->resampler.clear();
	s->filter.clear();
	blargg_err_t err = s->apu.load_spc(s->file.data(), (long) s->file.size());
	if (err)
		return err;
	s->filter.set_gain((int) (spc_gain * SPC_Filter::gain_unit));
	s->apu.clear_echo();
	s->apu.mute_voices(s->mute_mask);

	s->emu_track_ended = false;
	s->track_ended = false;

	if (!s->ignore_silence) {
		// Play until non-silence or end of track.
		for (long end = (long) max_initial_silence * out_channels * s->sample_rate; s->emu_time < end;) {
			fill_buf(s);
			if (s->buf_remain || s->emu_track_ended)
				break;
		}
		s->emu_time = s->buf_remain;
		s->out_time = 0;
		s->silence_time = 0;
		s->silence_count = 0;
	}

	// libgme callers set the fade after start_track, i.e. after the silence scan.
	if (s->user_fade_length_ms >= 0)
		apply_fade(s, s->user_fade_start_ms, s->user_fade_length_ms);
	return 0;
}

// Music_Emu::play
void play(rp_spc* s, long out_count, sample_t* out)
{
	if (s->track_ended) {
		memset(out, 0, out_count * sizeof *out);
	} else {
		// libgme's ignore_silence, extended to cover user muting.
		bool detect = !s->ignore_silence && !s->silence_detection_paused;
		long pos = 0;
		if (s->silence_count) {
			// During a run of silence, run the emulator ahead so it can find the end.
			long ahead_time = silence_lookahead * (s->out_time + out_count - s->silence_time) + s->silence_time;
			while (s->emu_time < ahead_time && !(s->buf_remain || s->emu_track_ended))
				fill_buf(s);

			pos = s->silence_count < out_count ? s->silence_count : out_count;
			memset(out, 0, pos * sizeof *out);
			s->silence_count -= pos;

			if (detect && s->emu_time - s->silence_time > (long) silence_max * out_channels * s->sample_rate) {
				s->track_ended = s->emu_track_ended = true;
				s->silence_count = 0;
				s->buf_remain = 0;
			}
		}

		if (s->buf_remain) {
			long n = s->buf_remain < out_count - pos ? s->buf_remain : out_count - pos;
			memcpy(&out[pos], s->buf.data() + (buf_size - s->buf_remain), n * sizeof *out);
			s->buf_remain -= n;
			pos += n;
		}

		long remain = out_count - pos;
		if (remain) {
			emu_play(s, remain, out + pos);
			s->track_ended = s->track_ended || s->emu_track_ended;

			if (detect || s->out_time > s->fade_start) {
				// Check the end for a new run of silence.
				long silence = count_silence(out + pos, remain);
				if (silence < remain)
					s->silence_time = s->emu_time - silence;

				if (s->emu_time - s->silence_time >= buf_size)
					fill_buf(s);  // causes silence detection on the next play
			}
		}

		if (s->fade_start >= 0 && s->out_time > s->fade_start)
			handle_fade(s, out_count, out);
	}
	s->out_time += out_count;
}

// Music_Emu::skip
void skip(rp_spc* s, long count)
{
	s->out_time += count;

	long n = count < s->silence_count ? count : s->silence_count;
	s->silence_count -= n;
	count -= n;

	n = count < s->buf_remain ? count : s->buf_remain;
	s->buf_remain -= n;
	count -= n;

	if (count && !s->emu_track_ended) {
		s->emu_time += count;
		end_track_if_error(s, skip_raw(s, count));
	}

	if (!(s->silence_count || s->buf_remain))
		s->track_ended = s->track_ended || s->emu_track_ended;
}

}  // namespace

extern "C" {

rp_spc* rp_spc_open(const void* data, long data_size_bytes, int output_rate_hz)
{
	if (!data || data_size_bytes < Snes_Spc::spc_min_file_size || output_rate_hz <= 0)
		return NULL;
	if (memcmp(data, "SNES-SPC700 Sound File Data", 27))
		return NULL;

	rp_spc* s = new (std::nothrow) rp_spc;
	if (!s)
		return NULL;
	s->file.assign((unsigned char const*) data, (unsigned char const*) data + data_size_bytes);
	s->buf.assign(buf_size, 0);
	s->sample_rate = output_rate_hz;
	s->resample = output_rate_hz != native_rate;
	s->ignore_silence = false;
	s->silence_detection_paused = false;
	s->mute_mask = 0;
	s->user_fade_start_ms = -1;
	s->user_fade_length_ms = -1;
	s->call_origin_output_samples = 0;
	s->capture_base_output_samples = 0;
	for (int v = 0; v < voice_count; v++) {
		s->previous_env_mode[v] = Spc_Dsp::env_release;
		s->previous_srcn[v] = -1;
	}
	clear_track_vars(s);

	if (s->apu.init()) {
		delete s;
		return NULL;
	}
	// Spc_Emu::set_sample_rate_ turns accuracy off, which disables
	// SPC_Filter's filtering; its gain stage still applies.
	s->filter.enable(false);
	if (s->resample) {
		if (s->resampler.buffer_size(native_rate / 20 * 2)) {
			delete s;
			return NULL;
		}
		s->resampler.time_ratio((double) native_rate / output_rate_hz, resampler_rolloff);
	}
	if (start_track(s)) {
		delete s;
		return NULL;
	}
	return s;
}

void rp_spc_close(rp_spc* s)
{
	delete s;
}

void rp_spc_set_fade(rp_spc* s, long start_ms, long length_ms)
{
	if (!s)
		return;
	s->user_fade_start_ms = start_ms;
	s->user_fade_length_ms = length_ms < 0 ? 0 : length_ms;
	apply_fade(s, start_ms, s->user_fade_length_ms);
}

void rp_spc_set_ignore_silence(rp_spc* s, int ignore)
{
	if (!s)
		return;
	s->ignore_silence = ignore != 0;
	// The leading-silence scan runs at track start, so restart to apply it.
	if (start_track(s))
		s->track_ended = s->emu_track_ended = true;
}

long rp_spc_play(rp_spc* s, float* out, long frames)
{
	if (!s || !out || frames <= 0)
		return 0;
	long count = frames * out_channels;
	if ((long) s->scratch.size() < count)
		s->scratch.resize(count);
	s->snapshots.clear();
	s->call_origin_output_samples = s->out_time;
	play(s, count, s->scratch.data());
	for (long i = 0; i < count; i++)
		out[i] = s->scratch[i] / 32768.0f;
	return frames;
}

int rp_spc_track_ended(rp_spc* s)
{
	return s && s->track_ended ? 1 : 0;
}

// Music_Emu::seek / seek_samples
int rp_spc_seek(rp_spc* s, long ms)
{
	if (!s || ms < 0)
		return 0;
	long time = msec_to_samples(s, ms);
	if (time < s->out_time && start_track(s))
		return 0;
	skip(s, time - s->out_time);
	return 1;
}

// Music_Emu::tell
long rp_spc_tell_ms(rp_spc* s)
{
	if (!s)
		return 0;
	long rate = s->sample_rate * out_channels;
	long sec = s->out_time / rate;
	return sec * 1000 + (s->out_time - sec * rate) * 1000 / rate;
}

void rp_spc_pause_silence_detection(rp_spc* s, int paused)
{
	if (!s)
		return;
	bool resuming = s->silence_detection_paused && !paused;
	s->silence_detection_paused = paused != 0;
	// Silence heard while paused must not count toward the 6 s window.
	if (resuming)
		s->silence_time = s->emu_time;
}

void rp_spc_mute_voices(rp_spc* s, int mask)
{
	if (!s)
		return;
	s->mute_mask = mask;
	s->apu.mute_voices(mask);
}

// Snapshot of the state the next rp_spc_play starts from, without emulating
// anything (so the audio is untouched): lets a paused seek show its new
// position. Replaces the previous call's snapshots; its frame is 0.
void rp_spc_capture_now(rp_spc* s)
{
	if (!s)
		return;
	s->snapshots.clear();
	s->call_origin_output_samples = s->out_time;
	s->capture_base_output_samples = s->out_time;
	capture_snapshot(s, 0);
}

int rp_spc_snapshot_size(void)
{
	return (int) sizeof(rp_spc_snapshot);
}

int rp_spc_snapshot_count(rp_spc* s)
{
	return s ? (int) s->snapshots.size() : 0;
}

const rp_spc_snapshot* rp_spc_snapshots(rp_spc* s)
{
	return s && !s->snapshots.empty() ? s->snapshots.data() : NULL;
}

void rp_spc_copy_ram(rp_spc* s, unsigned char* out)
{
	if (s && out)
		memcpy(out, s->apu.smp_ram(), 0x10000);
}

}  // extern "C"
