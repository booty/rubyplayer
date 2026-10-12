// rp_nsf: NSF/NSFe playback with 2A03 and expansion chip snapshots. See
// rp_nsf.h.

#include "rp_nsf.h"

#include "Nes_Fds_Apu.h"
#include "Nes_Fme7_Apu.h"
#include "Nes_Mmc5_Apu.h"
#include "Nes_Namco_Apu.h"
#include "Nes_Vrc6_Apu.h"
#include "Nes_Vrc7_Apu.h"
#include "Nsf_Emu.h"
#include "Nsfe_Emu.h"
#include "rp_recorder.h"

#include <stddef.h>
#include <string.h>

static_assert(sizeof(rp_nsf_snapshot) == 380, "rp_nsf_snapshot layout changed; update Nsf::Snapshot");
static_assert(offsetof(rp_nsf_snapshot, n163) == 247, "rp_nsf_snapshot layout changed; update Nsf::Snapshot");

namespace {

// Register-write snapshots closer together than this fold into one; their
// triggers accumulate. Changes in which voices sound, or how loud, are
// always recorded.
const long MIN_SNAPSHOTS_PER_SECOND = 240;
const int CLOCK_DIVISOR = 12;   // Nsf_Emu's play_period unit, 1/12 CPU clock
const uint64_t UNKNOWN = ~(uint64_t) 0;
// Nsf_Emu::cpu_write_misc's VRC7 data port range.
const unsigned VRC7_DATA_FIRST = 0x9028;
const unsigned VRC7_DATA_LAST = 0x9030;

// libgme's voice numbers for each chip present (-1: absent). See rp_nsf.h.
struct Voices {
	int vrc6 = -1, n163 = -1, s5b = -1, fds = -1, mmc5 = -1, vrc7 = -1;
	int count = Nes_Apu::osc_count;

	explicit Voices(int chips)
	{
		if (chips & RP_NSF_VRC6) { vrc6 = count; count += Nes_Vrc6_Apu::osc_count; }
		if (chips & RP_NSF_N163) { n163 = count; count += Nes_Namco_Apu::osc_count; }
		if (chips & RP_NSF_S5B)  { s5b  = count; count += Nes_Fme7_Apu::osc_count; }
		if (chips & RP_NSF_FDS)  { fds  = count; count += Nes_Fds_Apu::osc_count; }
		if (chips & RP_NSF_MMC5) { mmc5 = count; count += Nes_Mmc5_Apu::osc_count; }
		if (chips & RP_NSF_VRC7) { vrc7 = count; count += Nes_Vrc7_Apu::osc_count; }
	}
};

// What the NSF recorder does at each hook; one interface so the hooks,
// which receive an Nsf_Emu*, reach it for both Nsf_Emu and Nsfe_Emu.
class Nsf_Observer {
public:
	virtual ~Nsf_Observer() {}
	virtual void apu_write(unsigned addr, int data, long clock) = 0;
	virtual void expansion_write(unsigned addr, int data, long clock) = 0;
	virtual void driver_call(long clock) = 0;
	virtual void frame_end(long clock) = 0;
};

// The state of one oscillator that the frame counter changes: length
// counter, envelope, sweep, and linear counter, plus the registers they read
// (sweep rewrites the period).
struct Shadow_Osc {
	uint8_t regs[4];
	bool reg_written[4];
	int length;
	int envelope = 0, env_delay = 0;   // squares and noise
	int sweep_delay = 0;               // squares
	int linear = 0;                    // triangle

	void load(Nes_Osc const& osc)
	{
		memcpy(regs, osc.regs, sizeof regs);
		memcpy(reg_written, osc.reg_written, sizeof reg_written);
		length = osc.length_counter;
	}

	void load_envelope(Nes_Envelope const& osc)
	{
		load(osc);
		envelope = osc.envelope;
		env_delay = osc.env_delay;
	}

	// Nes_Osc::clock_length, Nes_Envelope::clock_envelope and volume,
	// Nes_Square::clock_sweep, and Nes_Triangle::clock_linear_counter.
	void clock_length(int halt_mask)
	{
		if (length && !(regs[0] & halt_mask))
			length--;
	}

	void clock_envelope()
	{
		int period = regs[0] & 15;
		if (reg_written[3]) {
			reg_written[3] = false;
			env_delay = period;
			envelope = 15;
		} else if (--env_delay < 0) {
			env_delay = period;
			if (envelope | (regs[0] & 0x20))
				envelope = (envelope - 1) & 15;
		}
	}

	int volume() const { return length == 0 ? 0 : (regs[0] & 0x10) ? (regs[0] & 15) : envelope; }

	int period() const { return (regs[3] & 7) * 0x100 + regs[2]; }

	void clock_sweep(int negative_adjust)
	{
		int sweep = regs[1];
		if (--sweep_delay < 0) {
			reg_written[1] = true;
			int period = this->period();
			int shift = sweep & Nes_Square::shift_mask;
			if (shift && (sweep & 0x80) && period >= 8) {
				int offset = period >> shift;
				if (sweep & Nes_Square::negate_flag)
					offset = negative_adjust - offset;
				if (period + offset < 0x800) {
					period += offset;
					regs[2] = period & 0xFF;
					regs[3] = (regs[3] & ~7) | ((period >> 8) & 7);
				}
			}
		}
		if (reg_written[1]) {
			reg_written[1] = false;
			sweep_delay = (sweep >> 4) & 7;
		}
	}

	void clock_linear_counter()
	{
		if (reg_written[3])
			linear = regs[0] & 0x7F;
		else if (linear)
			linear--;
		if (!(regs[0] & 0x80))
			reg_written[3] = false;
	}

	// Nes_Square::run's test for producing sound.
	bool square_playing() const
	{
		int period = this->period();
		int offset = (regs[1] & Nes_Square::negate_flag) ? 0 : period >> (regs[1] & Nes_Square::shift_mask);
		return volume() && period >= 8 && period + offset < 0x800;
	}

	bool triangle_playing() const { return length && linear && period() + 1 >= 3; }
};

// A 2A03-style APU's frame counter, simulated forward from the APU's state
// on copies. Advancing the real APU to watch it would split libgme's time
// spans differently, and libgme's triangle keeps its phase differently
// across a split while it has no output (all voices do during long seeks),
// which would change what is heard afterwards. The simulation is
// Nes_Apu::run_until_'s frame step, minus IRQs.
struct Shadow_Apu {
	Shadow_Osc square[2], triangle, noise;
	nes_time_t time;   // when the next step is due
	int frame, frame_period, frame_mode;
	bool pal;

	void load(Nes_Apu const& apu)
	{
		for (int i = 0; i < 2; i++) {
			square[i].load_envelope(apu.rp_square(i));
			square[i].sweep_delay = apu.rp_square(i).sweep_delay;
		}
		triangle.load(apu.rp_triangle());
		triangle.linear = apu.rp_triangle().linear_counter;
		noise.load_envelope(apu.rp_noise());
		time = apu.rp_last_time() + apu.rp_frame_delay();
		frame = apu.rp_frame();
		frame_period = apu.rp_frame_period();
		frame_mode = apu.rp_frame_mode();
		pal = apu.rp_dmc().pal_mode;
	}

	void step()
	{
		int delay = frame_period;
		switch (frame++) {
		case 0:
		case 2:
			square[0].clock_length(0x20);
			square[1].clock_length(0x20);
			noise.clock_length(0x20);
			triangle.clock_length(0x80);
			square[0].clock_sweep(-1);
			square[1].clock_sweep(0);
			if (pal && frame == 3)
				delay -= 2;
			break;
		case 1:
			if (!pal)
				delay -= 2;
			break;
		case 3:
			frame = 0;
			if (frame_mode & 0x80)
				delay += frame_period - (pal ? 2 : 6);
			break;
		}
		triangle.clock_linear_counter();
		square[0].clock_envelope();
		square[1].clock_envelope();
		noise.clock_envelope();
		time += delay;
	}

	// Writes the simulated state over a 2A03 snapshot block.
	void store_apu(rp_nsf_snapshot& snap) const
	{
		for (int i = 0; i < 2; i++) {
			memcpy(snap.apu_regs + i * 4, square[i].regs, 4);
			snap.apu_volume[i] = (uint8_t) square[i].volume();
			snap.apu_length[i] = (uint16_t) square[i].length;
		}
		snap.apu_length[2] = (uint16_t) triangle.length;
		snap.tri_linear = (uint8_t) triangle.linear;
		snap.apu_volume[2] = (uint8_t) noise.volume();
		snap.apu_length[3] = (uint16_t) noise.length;
		snap.playing = (snap.playing & ~15u) | (square[0].square_playing() ? 1 : 0) |
				(square[1].square_playing() ? 2 : 0) | (triangle.triangle_playing() ? 4 : 0) |
				(noise.volume() ? 8 : 0);
	}

	// The same for the MMC5's two squares, at voice `base`.
	void store_mmc5(rp_nsf_snapshot& snap, int base) const
	{
		for (int i = 0; i < 2; i++) {
			memcpy(snap.mmc5_regs + i * 4, square[i].regs, 4);
			snap.mmc5_volume[i] = (uint8_t) square[i].volume();
			snap.mmc5_length[i] = (uint16_t) square[i].length;
			snap.playing &= ~(1u << (base + i));
			if (square[i].square_playing())
				snap.playing |= 1u << (base + i);
		}
	}
};

// Sound-producing voices of the real 2A03, from bit 0, by the same rules.
uint32_t apu_playing(Nes_Apu const& apu)
{
	Shadow_Apu shadow;
	shadow.load(apu);
	uint32_t bits = (shadow.square[0].square_playing() ? 1 : 0) | (shadow.square[1].square_playing() ? 2 : 0) |
			(shadow.triangle.triangle_playing() ? 4 : 0) | (shadow.noise.volume() ? 8 : 0);
	if (apu.rp_dmc().length_counter)
		bits |= 16;
	return bits;
}

// What is heard: which voices sound, and the envelope volumes of those with
// frame-counter envelopes.
uint64_t audible(rp_nsf_snapshot const& snap)
{
	return snap.playing | (uint64_t) snap.apu_volume[0] << 32 | (uint64_t) snap.apu_volume[1] << 36 |
			(uint64_t) snap.apu_volume[2] << 40 | (uint64_t) snap.mmc5_volume[0] << 44 |
			(uint64_t) snap.mmc5_volume[1] << 48;
}

template <class Base>
class Rp_Nsf : public rp::Recorder<Base, rp_nsf_snapshot>, public Nsf_Observer {
public:
	uint32_t triggers = 0;
	// audible() of the latest queued snapshot.
	uint64_t last_audible = UNKNOWN;
	// Absolute clock of the latest frame-counter step simulated and recorded.
	int64_t stepped_through = rp::NO_CLOCK;

	int chips() const { return this->header().chip_flags & 0x3F; }

	void fill(rp_nsf_snapshot& snap) const
	{
		memset(&snap, 0, sizeof snap);
		Voices voices(chips());
		snap.chips = (uint8_t) chips();
		snap.pal = this->rp_pal();
		snap.voice_count = (uint8_t) voices.count;
		snap.play_period = (uint32_t) (this->rp_play_period() / CLOCK_DIVISOR);
		snap.clock_rate = (uint32_t) (this->rp_clock_rate() + 0.5);
		fill_apu(snap);
		snap.playing = apu_playing(this->rp_apu()) | expansion_playing(voices);
		if (Nes_Mmc5_Apu const* mmc5 = this->rp_mmc5()) {
			for (int i = 0; i < 2; i++) {
				Nes_Square const& square = mmc5->rp_square(i);
				memcpy(snap.mmc5_regs + i * 4, square.regs, 4);
				snap.mmc5_volume[i] = (uint8_t) square.volume();
				snap.mmc5_length[i] = (uint16_t) square.length_counter;
			}
			snap.mmc5_status = (uint8_t) mmc5->rp_osc_enables();
			snap.mmc5_pcm = (uint8_t) mmc5->rp_dmc().dac;
		}
		if (Nes_Vrc6_Apu const* vrc6 = this->rp_vrc6()) {
			vrc6_apu_state_t state;
			vrc6->save_state(&state);
			memcpy(snap.vrc6_regs, state.regs, sizeof snap.vrc6_regs);
		}
		if (Nes_Fme7_Apu const* fme7 = this->rp_fme7()) {
			fme7_apu_state_t state;
			fme7->save_state(&state);
			memcpy(snap.s5b_regs, state.regs, sizeof snap.s5b_regs);
		}
		if (Nes_Vrc7_Apu const* vrc7 = this->rp_vrc7()) {
			vrc7_snapshot_t state;
			vrc7->save_snapshot(&state);
			memcpy(snap.vrc7_custom, state.inst, sizeof snap.vrc7_custom);
			memcpy(snap.vrc7_regs, state.regs, sizeof snap.vrc7_regs);
		}
		if (Nes_Fds_Apu const* fds = this->rp_fds()) {
			memcpy(snap.fds_regs, fds->rp_regs() + 0x40, sizeof snap.fds_regs);
			memcpy(snap.fds_wave, fds->rp_regs(), sizeof snap.fds_wave);
			for (int i = 0; i < 32; i++)
				snap.fds_mod[i] = fds->rp_mod_wave()[i * 2];
			snap.fds_env_gain = (uint8_t) fds->rp_env_gain();
			snap.fds_sweep_gain = (uint8_t) fds->rp_sweep_gain();
		}
		if (Nes_Namco_Apu const* namco = this->rp_namco()) {
			memcpy(snap.n163, namco->rp_regs(), sizeof snap.n163);
			snap.n163_active = (uint8_t) (((namco->rp_regs()[0x7F] >> 4) & 7) + 1);
		}
	}

	void apu_write(unsigned addr, int data, long clock) override
	{
		if (!this->recording)
			return;

		before_write(clock);
		switch (addr) {
		case 0x03: triggers |= 1; break;
		case 0x07: triggers |= 2; break;
		case 0x0B: triggers |= 4; break;
		case 0x0F: triggers |= 8; break;
		case 0x15:
			// The DMC only (re)starts when it has no sample bytes left.
			if ((data & 0x10) && !this->rp_apu().rp_dmc().length_counter)
				triggers |= 16;
			break;
		}
		wrote_at(clock);
	}

	void expansion_write(unsigned addr, int data, long clock) override
	{
		if (!this->recording)
			return;

		before_write(clock);
		Voices voices(chips());
		if (voices.mmc5 >= 0 && (addr == 0x5003 || addr == 0x5007))
			triggers |= 1u << (voices.mmc5 + (addr == 0x5007));
		if (voices.vrc7 >= 0 && addr >= VRC7_DATA_FIRST && addr <= VRC7_DATA_LAST) {
			// Key on (bit 4 of $20-$25) rising: the note restarts.
			vrc7_snapshot_t state;
			this->rp_vrc7()->save_snapshot(&state);
			int channel = state.latch - 0x20;
			if (channel >= 0 && channel < 6 && (data & 0x10) && !(state.regs[channel][1] & 0x10))
				triggers |= 1u << (voices.vrc7 + channel);
		}
		wrote_at(clock);
	}

	void driver_call(long clock) override
	{
		if (!this->recording)
			return;

		Steps steps = observe_writes(clock);
		// The registers the previous driver call left, at its last write (when
		// they were heard) rather than this call's start, a driver period later.
		int64_t interval = (int64_t) this->rp_clock_rate() / MIN_SNAPSHOTS_PER_SECOND;
		if (this->wrote && (this->last_push == rp::NO_CLOCK || this->last_write - this->last_push >= interval))
			push(steps.state(*this), this->last_write);
		step_to(steps, clock);
	}

	void frame_end(long clock) override
	{
		if (!this->recording)
			return;

		Steps steps = observe_writes(clock);
		step_to(steps, clock);
	}

protected:
	void reset_recording() override
	{
		triggers = 0;
		last_audible = UNKNOWN;
		stepped_through = rp::NO_CLOCK;
	}

private:
	// The frame counters of the 2A03 and (when present) MMC5, simulated
	// from the chips' current state: the chips themselves run lazily, so
	// steps since their last run are still to come.
	struct Steps {
		Shadow_Apu apu, mmc5;
		bool has_mmc5;
		int mmc5_voice;

		explicit Steps(Rp_Nsf const& emu)
		{
			apu.load(emu.rp_apu());
			has_mmc5 = emu.rp_mmc5() != NULL;
			mmc5_voice = Voices(emu.chips()).mmc5;
			if (has_mmc5)
				mmc5.load(*emu.rp_mmc5());
		}

		nes_time_t next() const { return has_mmc5 && mmc5.time < apu.time ? mmc5.time : apu.time; }

		// Runs the earlier counter's next step; returns its time.
		nes_time_t step()
		{
			nes_time_t time = next();
			if (has_mmc5 && mmc5.time == time)
				mmc5.step();
			if (apu.time == time)
				apu.step();
			return time;
		}

		// The chips' state with the simulated steps applied.
		rp_nsf_snapshot state(Rp_Nsf const& emu) const
		{
			rp_nsf_snapshot snap;
			emu.fill(snap);
			apu.store_apu(snap);
			if (has_mmc5)
				mmc5.store_mmc5(snap, mmc5_voice);
			return snap;
		}
	};

	void fill_apu(rp_nsf_snapshot& snap) const
	{
		Nes_Apu const& apu = this->rp_apu();
		for (int i = 0; i < 2; i++) {
			Nes_Square const& square = apu.rp_square(i);
			memcpy(snap.apu_regs + i * 4, square.regs, 4);
			snap.apu_volume[i] = (uint8_t) square.volume();
			snap.apu_length[i] = (uint16_t) square.length_counter;
		}
		Nes_Triangle const& triangle = apu.rp_triangle();
		memcpy(snap.apu_regs + 8, triangle.regs, 4);
		snap.apu_length[2] = (uint16_t) triangle.length_counter;
		snap.tri_linear = (uint8_t) triangle.linear_counter;
		Nes_Noise const& noise = apu.rp_noise();
		memcpy(snap.apu_regs + 12, noise.regs, 4);
		snap.apu_volume[2] = (uint8_t) noise.volume();
		snap.apu_length[3] = (uint16_t) noise.length_counter;
		Nes_Dmc const& dmc = apu.rp_dmc();
		memcpy(snap.apu_regs + 16, dmc.regs, 4);
		snap.apu_length[4] = (uint16_t) dmc.length_counter;
		snap.dmc_dac = (uint8_t) dmc.dac;
		snap.dmc_address = (uint16_t) dmc.address;
		snap.apu_status = (uint8_t) apu.rp_osc_enables();
		snap.apu_frame_mode = (uint8_t) apu.rp_frame_mode();
	}

	// Expansion voices that sound, by libgme's rules for each chip.
	uint32_t expansion_playing(Voices const& voices) const
	{
		uint32_t bits = 0;
		if (Nes_Vrc6_Apu const* vrc6 = this->rp_vrc6()) {
			vrc6_apu_state_t state;
			vrc6->save_state(&state);
			// Saw first, as libgme numbers it; its rate is the accumulator step.
			if ((state.regs[2][2] & 0x80) && (state.regs[2][0] & 0x3F))
				bits |= 1u << voices.vrc6;
			for (int i = 0; i < 2; i++) {
				if ((state.regs[i][2] & 0x80) && (state.regs[i][0] & 0x0F))
					bits |= 1u << (voices.vrc6 + 1 + i);
			}
		}
		if (Nes_Namco_Apu const* namco = this->rp_namco()) {
			uint8_t const* reg = namco->rp_regs();
			int active = ((reg[0x7F] >> 4) & 7) + 1;
			for (int i = Nes_Namco_Apu::osc_count - active; i < Nes_Namco_Apu::osc_count; i++) {
				uint8_t const* osc = reg + 0x40 + i * 8;
				int32_t freq = (osc[4] & 3) * 0x10000 + osc[2] * 0x100 + osc[0];
				int wave_size = 32 - ((osc[4] >> 2) & 7) * 4;
				if ((osc[4] & 0xE0) && (osc[7] & 15) && freq >= 64 * active && wave_size)
					bits |= 1u << (voices.n163 + i);
			}
		}
		if (Nes_Fme7_Apu const* fme7 = this->rp_fme7()) {
			fme7_apu_state_t state;
			fme7->save_state(&state);
			for (int i = 0; i < 3; i++) {
				int volume = state.regs[8 + i];
				int period = ((state.regs[i * 2 + 1] & 0x0F) * 0x100 + state.regs[i * 2]) * 16;
				// libgme plays tone only: noise and envelope modes are silent.
				if (!((state.regs[7] >> i) & 1) && !(volume & 0x10) && (volume & 0x0F) && period >= 50)
					bits |= 1u << (voices.s5b + i);
			}
		}
		if (Nes_Fds_Apu const* fds = this->rp_fds()) {
			uint8_t const* regs = fds->rp_regs() + 0x40;   // $4080
			int freq = (regs[3] & 0x0F) * 0x100 + regs[2];
			if (freq && !((regs[9] | regs[3]) & 0x80) && fds->rp_env_gain())
				bits |= 1u << voices.fds;
		}
		if (Nes_Mmc5_Apu const* mmc5 = this->rp_mmc5()) {
			Shadow_Apu shadow;
			shadow.load(*mmc5);
			for (int i = 0; i < 2; i++) {
				if (shadow.square[i].square_playing())
					bits |= 1u << (voices.mmc5 + i);
			}
		}
		if (Nes_Vrc7_Apu const* vrc7 = this->rp_vrc7()) {
			vrc7_snapshot_t state;
			vrc7->save_snapshot(&state);
			for (int i = 0; i < 6; i++) {
				if (state.regs[i][1] & 0x10)
					bits |= 1u << (voices.vrc7 + i);
			}
		}
		return bits;
	}

	void push(rp_nsf_snapshot snap, int64_t label)
	{
		snap.triggers = triggers;
		this->queue(snap, label);
		triggers = 0;
		last_audible = audible(snap);
	}

	// The chips run lazily: until something advances them, their state is the
	// one the latest write left (plus the frame-counter steps already
	// simulated). So at each hook, a change since the previous one came from
	// that write (a length reload, a key on) and is recorded at its time,
	// even when the note it started has already ended by now. Returns the
	// simulation, advanced to the latest recorded step.
	Steps observe_writes(long clock)
	{
		Steps steps(*this);
		while (steps.next() < clock && this->absolute(steps.next()) <= stepped_through)
			steps.step();
		rp_nsf_snapshot snap = steps.state(*this);
		if (audible(snap) != last_audible)
			push(snap, this->wrote ? this->last_write : this->absolute(clock));
		return steps;
	}

	// A driver's writes for one note land together, so only a frame-counter
	// step due before this write, which would change the state they leave,
	// records it now; the driver call after them does otherwise.
	void before_write(long clock)
	{
		Steps steps(*this);
		while (steps.next() < clock && this->absolute(steps.next()) <= stepped_through)
			steps.step();
		if (steps.next() < clock) {
			steps = observe_writes(clock);
			step_to(steps, clock);
		}
	}

	void wrote_at(long clock)
	{
		this->last_write = this->absolute(clock);
		this->wrote = true;
	}

	// Simulates the frame-counter steps due before `clock` (the only moments
	// length counters, envelopes, the linear counter, and sweep act),
	// recording each that changes what is heard.
	void step_to(Steps& steps, long clock)
	{
		while (steps.next() < clock) {
			int64_t time = this->absolute(steps.step());
			stepped_through = time;
			rp_nsf_snapshot snap = steps.state(*this);
			if (audible(snap) != last_audible)
				push(snap, time);
		}
	}
};

typedef Rp_Nsf<Nsf_Emu> Rp_Nsf_Emu;
typedef Rp_Nsf<Nsfe_Emu> Rp_Nsfe_Emu;

Music_Emu* new_rp_nsf_emu() { return new Rp_Nsf_Emu; }
Music_Emu* new_rp_nsfe_emu() { return new Rp_Nsfe_Emu; }

// libgme's NSF and NSFe types with our subclasses as the emulators.
gme_type_t_ with_emu(gme_type_t type, Music_Emu* (*new_emu)())
{
	gme_type_t_ copy = *type;
	copy.new_emu = new_emu;
	return copy;
}

const gme_type_t_ RP_NSF_TYPE = with_emu(gme_nsf_type, &new_rp_nsf_emu);
const gme_type_t_ RP_NSFE_TYPE = with_emu(gme_nsfe_type, &new_rp_nsfe_emu);

Nsf_Observer& observer(Nsf_Emu* emu)
{
	// Every Nsf_Emu in this library comes from RP_NSF_TYPE or RP_NSFE_TYPE.
	return *dynamic_cast<Nsf_Observer*>(emu);
}

} // namespace

// Called from the vendored core (rp_nsf_hooks.h).
void rp_nsf_apu_write(Nsf_Emu* emu, unsigned addr, int data, long clock) { observer(emu).apu_write(addr, data, clock); }
void rp_nsf_expansion_write(Nsf_Emu* emu, unsigned addr, int data, long clock)
{
	observer(emu).expansion_write(addr, data, clock);
}
void rp_nsf_driver_call(Nsf_Emu* emu, long clock) { observer(emu).driver_call(clock); }
void rp_nsf_frame_end(Nsf_Emu* emu, long clock) { observer(emu).frame_end(clock); }

// The handle holds whichever emulator the data needs; both share the C API
// below through this interface.
struct rp_nsf {
	virtual ~rp_nsf() {}
	virtual Music_Emu* music() = 0;
	virtual int start_track(int track) = 0;
	virtual int play(float* out, long frames) = 0;
	virtual int seek(long ms) = 0;
	virtual void capture_now() = 0;
	virtual std::vector<rp_nsf_snapshot> const& snapshots() = 0;
};

namespace {

template <class Emu>
struct Nsf_Handle : rp_nsf, rp::Player<Emu> {
	Music_Emu* music() override { return this->emu; }
	int start_track(int track) override { return rp::start_track(this, track); }
	int play(float* out, long frames) override { return rp::play(this, out, frames); }
	int seek(long ms) override { return rp::seek(this, ms); }
	void capture_now() override
	{
		rp::capture_now(this, [](Emu& emu, rp_nsf_snapshot& snap) { emu.fill(snap); });
	}
	std::vector<rp_nsf_snapshot> const& snapshots() override { return this->emu->snapshots; }
	~Nsf_Handle() override { gme_delete(this->emu); }
};

template <class Emu>
rp_nsf* open_as(gme_type_t type, const void* data, long size, int out_rate)
{
	Music_Emu* music = gme_new_emu(type, out_rate);
	if (!music)
		return NULL;
	if (gme_load_data(music, data, size)) {
		gme_delete(music);
		return NULL;
	}
	Nsf_Handle<Emu>* handle = new Nsf_Handle<Emu>;
	handle->emu = static_cast<Emu*>(music);
	return handle;
}

} // namespace

extern "C" {

rp_nsf* rp_nsf_open(const void* data, long size, int out_rate)
{
	if (!data || size < 4)
		return NULL;
	if (!memcmp(data, "NSFE", 4))
		return open_as<Rp_Nsfe_Emu>(&RP_NSFE_TYPE, data, size, out_rate);
	return open_as<Rp_Nsf_Emu>(&RP_NSF_TYPE, data, size, out_rate);
}

void rp_nsf_close(rp_nsf* handle) { delete handle; }

int rp_nsf_load_m3u(rp_nsf* handle, const void* data, long size)
{
	if (!handle || !data || size <= 0)
		return 0;
	return gme_load_m3u_data(handle->music(), data, size) == NULL;
}

int rp_nsf_start_track(rp_nsf* handle, int track) { return handle ? handle->start_track(track) : 0; }

void rp_nsf_set_fade(rp_nsf* handle, long start_ms)
{
	if (handle)
		gme_set_fade(handle->music(), (int) start_ms);
}

void rp_nsf_ignore_silence(rp_nsf* handle, int ignore)
{
	if (handle)
		gme_ignore_silence(handle->music(), ignore);
}

int rp_nsf_play(rp_nsf* handle, float* out, long frames) { return handle ? handle->play(out, frames) : 0; }

int rp_nsf_track_ended(rp_nsf* handle) { return handle ? gme_track_ended(handle->music()) : 1; }

int rp_nsf_seek(rp_nsf* handle, long ms) { return handle ? handle->seek(ms) : 0; }

long rp_nsf_tell_ms(rp_nsf* handle) { return handle ? gme_tell(handle->music()) : 0; }

void rp_nsf_mute_voices(rp_nsf* handle, int mask)
{
	if (handle)
		gme_mute_voices(handle->music(), mask);
}

int rp_nsf_voice_count(rp_nsf* handle) { return handle ? gme_voice_count(handle->music()) : 0; }

int rp_nsf_snapshot_size(void) { return (int) sizeof(rp_nsf_snapshot); }

int rp_nsf_snapshot_count(rp_nsf* handle) { return handle ? (int) handle->snapshots().size() : 0; }

const rp_nsf_snapshot* rp_nsf_snapshots(rp_nsf* handle)
{
	return handle && !handle->snapshots().empty() ? handle->snapshots().data() : NULL;
}

void rp_nsf_capture_now(rp_nsf* handle)
{
	if (handle)
		handle->capture_now();
}

} // extern "C"
