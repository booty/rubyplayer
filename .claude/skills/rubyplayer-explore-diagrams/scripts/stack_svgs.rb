# frozen_string_literal: true

# Stacks Mermaid-rendered SVGs vertically into one SVG, each under a caption,
# with an optional plain-text legend at the bottom. Stdlib only, so it runs
# outside the project's bundle.
#
#   ruby stack_svgs.rb --out OUT.svg --title TITLE [--legend LEGEND.txt] "Caption::part.svg" ...

require 'optparse'

GAP_PX = 32
TITLE_FONT_PX = 22
CAPTION_FONT_PX = 17
LEGEND_FONT_PX = 13
LEGEND_LINE_PX = 18
MARGIN_PX = 16

def escape_xml(text)
  text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
end

def text_line(text, y_px, size_px, weight: 'normal', family: 'sans-serif')
  %(<text x="#{MARGIN_PX}" y="#{y_px}" font-family="#{family}" font-size="#{size_px}" ) +
    %(font-weight="#{weight}" fill="#333">#{escape_xml(text)}</text>)
end

options = {}
OptionParser.new do |parser|
  parser.on('--out PATH') { |path| options[:out] = path }
  parser.on('--title TEXT') { |text| options[:title] = text }
  parser.on('--legend PATH') { |path| options[:legend] = path }
end.parse!

abort 'usage: stack_svgs.rb --out OUT.svg --title TITLE [--legend FILE] "Caption::part.svg" ...' if
  options[:out].nil? || ARGV.empty?

y_px = MARGIN_PX
body = []
width_px = 0.0

if options[:title]
  y_px += TITLE_FONT_PX
  body << text_line(options[:title], y_px, TITLE_FONT_PX, weight: 'bold')
  y_px += GAP_PX / 2
end

ARGV.each_with_index do |spec, index|
  caption, path = spec.split('::', 2)
  svg = File.read(path)
  # mmdc gives every SVG id="my-svg" and scopes its CSS and marker ids to it;
  # stacked copies would restyle each other, so give each its own id.
  svg = svg.gsub('my-svg', "stacked-part-#{index}")
  view_box = svg[/<svg\b[^>]*\bviewBox="([^"]+)"/, 1] or abort "no viewBox in #{path}"
  part_width_px, part_height_px = view_box.split.map(&:to_f).last(2)

  y_px += CAPTION_FONT_PX
  body << text_line(caption, y_px, CAPTION_FONT_PX, weight: 'bold')
  y_px += 8

  # Replace the root's responsive sizing (width="100%", max-width) with a
  # fixed box at this part's offset; nested <svg> elements accept x/y.
  root = svg[/<svg\b[^>]*>/]
  placement = %(x="#{MARGIN_PX}" y="#{y_px}" width="#{part_width_px}" height="#{part_height_px}")
  sized_root = root.sub(/\swidth="[^"]*"/, '').sub(/\sstyle="[^"]*"/, '').sub('<svg', "<svg #{placement}")
  body << svg.sub(/\A.*?<svg\b[^>]*>/m, sized_root)

  y_px += part_height_px + GAP_PX
  width_px = [width_px, part_width_px].max
end

if options[:legend]
  File.readlines(options[:legend], chomp: true).each do |line|
    y_px += LEGEND_LINE_PX
    body << text_line(line, y_px, LEGEND_FONT_PX, family: 'monospace')
    # Monospace glyphs are ~0.6 em wide; widen the canvas for long lines.
    width_px = [width_px, line.length * LEGEND_FONT_PX * 0.6].max
  end
  y_px += MARGIN_PX
end

total_width_px = (width_px + (2 * MARGIN_PX)).ceil
total_height_px = y_px.ceil
File.write(options[:out], <<~SVG)
  <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="#{total_width_px}" height="#{total_height_px}" viewBox="0 0 #{total_width_px} #{total_height_px}">
  <rect width="100%" height="100%" fill="white"/>
  #{body.join("\n")}
  </svg>
SVG
puts options[:out]
