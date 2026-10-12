# frozen_string_literal: true

require_relative 'brr'

module RubyPlayer
  module Spc
    # Splits the SPC's 64 KB RAM into labelled regions for the live view's map.
    module RamMap
      RAM_BYTES = 0x10000
      # Higher wins where regions overlap. Echo is rewritten continuously by
      # the DSP, so it beats any "sample" that a junk entry claims there.
      KINDS = %i[other samples directory echo].freeze
      ENTRY_BYTES = 4

      module_function

      # Sorted, non-overlapping {kind:, from:, to:} ranges (to exclusive)
      # covering all of RAM. `directory` is Brr.directory's result.
      def regions(global:, directory:)
        rank = Array.new(RAM_BYTES, 0)
        directory.each do |entry|
          info = entry[:info]
          mark(rank, :samples, entry[:start], info[:end_addr] + Brr::BLOCK_BYTES) if info
        end
        dir = global[:dir] * 0x100
        mark(rank, :directory, dir, dir + (ENTRY_BYTES * ((directory.map { |entry| entry[:srcn] }.max || -1) + 1)))
        echo = global[:esa] * 0x100
        mark(rank, :echo, echo, echo + global[:echo_bytes])
        runs(rank)
      end

      # Ranges may wrap past $FFFF, as the hardware's addressing does.
      def mark(rank, kind, from, to)
        level = KINDS.index(kind)
        (from...to).each do |address|
          index = address % RAM_BYTES
          rank[index] = level if rank[index] < level
        end
      end

      def runs(rank)
        regions = []
        from = 0
        (1..RAM_BYTES).each do |address|
          next if address < RAM_BYTES && rank[address] == rank[from]

          regions << { kind: KINDS[rank[from]], from: from, to: address }
          from = address
        end
        regions
      end
    end
  end
end
