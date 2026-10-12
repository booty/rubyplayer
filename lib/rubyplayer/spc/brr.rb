# frozen_string_literal: true

module RubyPlayer
  module Spc
    # Reads the S-DSP sample directory and BRR-compressed samples from SPC RAM.
    # Display-only: decoding is an approximate preview, not bit-exact playback.
    module Brr
      BLOCK_BYTES = 9
      SAMPLES_PER_BLOCK = 16
      MAX_BLOCKS = 4096
      MIN_ADDRESS = 0x0200 # below this is zero page, stack, and I/O ports
      MAX_SHIFT = 12
      RAM_BYTES = 0x10000
      # Directory slots past the last sample in use are trusted only until
      # this many invalid slots in a row; the rest of the page is usually
      # unrelated data that can still look like a sample by chance.
      GAP_LIMIT = 16

      module_function

      # Entries worth listing: plausible samples, plus anything a voice is
      # using (marked valid: false if it doesn't look like a sample).
      def directory(ram, dir, in_use: [])
        last_in_use = in_use.max || -1
        gap = 0
        (0..255).each_with_object([]) do |srcn, entries|
          start, loop = entry_addresses(ram, dir, srcn)
          info = plausible?(ram, start) ? sample_info(ram, start, loop) : nil
          gap = info ? 0 : gap + 1
          break entries if gap > GAP_LIMIT && srcn > last_in_use
          next unless info || in_use.include?(srcn)

          entries << { srcn: srcn, start: start, loop: loop, valid: !info.nil?, info: info }
        end
      end

      # Walks blocks from `start` to the end flag. Nil when there is none, the
      # walk leaves RAM, or a looping sample's loop point isn't one of its blocks.
      def sample_info(ram, start, loop)
        address = start
        MAX_BLOCKS.times do |index|
          return nil if address + BLOCK_BYTES > RAM_BYTES

          header = ram.getbyte(address)
          if header[0] == 1
            blocks = index + 1
            looped = header[1] == 1
            return nil if looped && !loop_block?(start, loop, address)

            return { blocks: blocks, samples: blocks * SAMPLES_PER_BLOCK,
                     bytes: blocks * BLOCK_BYTES, looped: looped, end_addr: address }
          end
          address += BLOCK_BYTES
        end
        nil
      end

      def decode(ram, start, max_samples:)
        samples = []
        previous = older = 0
        address = start
        while samples.size < max_samples && address + BLOCK_BYTES <= RAM_BYTES
          header = ram.getbyte(address)
          ram.byteslice(address + 1, 8).each_byte do |byte|
            [byte >> 4, byte & 0x0f].each do |nibble|
              value = predict(nibble, header, previous, older)
              older = previous
              previous = value
              samples << value
            end
          end
          break if header[0] == 1

          address += BLOCK_BYTES
        end
        samples.first(max_samples)
      end

      def entry_addresses(ram, dir, srcn)
        offset = (dir * 0x100) + (srcn * 4)
        bytes = Array.new(4) { |index| ram.getbyte((offset + index) % RAM_BYTES) }
        [bytes[0] | (bytes[1] << 8), bytes[2] | (bytes[3] << 8)]
      end

      # Encoders always start a sample with filter 0 (no history to predict
      # from) and a valid shift, which rules out most junk directory slots.
      def plausible?(ram, start)
        return false if start < MIN_ADDRESS || start + BLOCK_BYTES > RAM_BYTES

        header = ram.getbyte(start)
        (header >> 2).nobits?(0x03) && (header >> 4) <= MAX_SHIFT
      end

      def loop_block?(start, loop, end_addr)
        loop.between?(start, end_addr) && ((loop - start) % BLOCK_BYTES).zero?
      end

      # One BRR sample from a 4-bit nibble and the two previous outputs.
      def predict(nibble, header, previous, older)
        signed = nibble >= 8 ? nibble - 16 : nibble
        shift = header >> 4
        base = if shift <= MAX_SHIFT
                 (signed << shift) >> 1
               else
                 (signed.negative? ? -2048 : 0)
               end
        value = case (header >> 2) & 0x03
                when 0 then base
                when 1 then base + previous + (-previous >> 4)
                when 2 then base + (previous << 1) + ((-previous * 3) >> 5) - older + (older >> 4)
                else base + (previous << 1) + ((-previous * 13) >> 6) - older + ((older * 3) >> 4)
                end
        value.clamp(-32_768, 32_767)
      end
    end
  end
end
