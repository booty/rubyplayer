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
	int mute_mask;
	// User fade survives restarts (backward seeks); libgme would instead fall
	// back to Spc_Emu's (length, 50 ms) default after a restart.
	long user_fade_start_ms;
	long user_fade_length_ms;

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

// Spc_Emu::play_and_filter
blargg_err_t play_and_filter(rp_spc* s, long count, sample_t* out)
{
	blargg_err_t err = s->apu.play((int) count, out);
	if (err)
		return err;
	s->filter.run(out, (int) count);
	return 0;
}

// Spc_Emu::play_
blargg_err_t play_raw(rp_spc* s, long count, sample_t* out)
{
	if (!s->resample)
		return play_and_filter(s, count, out);

	long remain = count;
	while (remain > 0) {
		remain -= s->resampler.read(&out[count - remain], (int) remain);
		if (remain > 0) {
			long n = s->resampler.max_write();
			blargg_err_t err = play_and_filter(s, n, s->resampler.buffer());
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
	return play_raw(s, resampler_latency, discard);
}

// Music_Emu::emu_play
void emu_play(rp_spc* s, long count, sample_t* out)
{
	s->emu_time += count;
	if (!s->emu_track_ended)
		end_track_if_error(s, play_raw(s, count, out));
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
		long pos = 0;
		if (s->silence_count) {
			// During a run of silence, run the emulator ahead so it can find the end.
			long ahead_time = silence_lookahead * (s->out_time + out_count - s->silence_time) + s->silence_time;
			while (s->emu_time < ahead_time && !(s->buf_remain || s->emu_track_ended))
				fill_buf(s);

			pos = s->silence_count < out_count ? s->silence_count : out_count;
			memset(out, 0, pos * sizeof *out);
			s->silence_count -= pos;

			if (!s->ignore_silence && s->emu_time - s->silence_time > (long) silence_max * out_channels * s->sample_rate) {
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

			if (!s->ignore_silence || s->out_time > s->fade_start) {
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

rp_spc* rp_spc_open(const void* data, long size, int out_rate)
{
	if (!data || size < Snes_Spc::spc_min_file_size || out_rate <= 0)
		return NULL;
	if (memcmp(data, "SNES-SPC700 Sound File Data", 27))
		return NULL;

	rp_spc* s = new (std::nothrow) rp_spc;
	if (!s)
		return NULL;
	s->file.assign((unsigned char const*) data, (unsigned char const*) data + size);
	s->buf.assign(buf_size, 0);
	s->sample_rate = out_rate;
	s->resample = out_rate != native_rate;
	s->ignore_silence = false;
	s->mute_mask = 0;
	s->user_fade_start_ms = -1;
	s->user_fade_length_ms = -1;
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
		s->resampler.time_ratio((double) native_rate / out_rate, resampler_rolloff);
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

void rp_spc_mute_voices(rp_spc* s, int mask)
{
	if (!s)
		return;
	s->mute_mask = mask;
	s->apu.mute_voices(mask);
}

int rp_spc_snapshot_size(void) { return 0; }
int rp_spc_snapshot_count(rp_spc*) { return 0; }
const void* rp_spc_snapshots(rp_spc*) { return NULL; }
void rp_spc_copy_ram(rp_spc*, unsigned char*) { }

}  // extern "C"
