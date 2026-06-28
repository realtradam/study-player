# Minimal JSON encoder (this mruby gembox has no JSON gem). Shared by the agent
# bridge (R1) and the Log pipeline (R2). Handles the value types we actually emit:
# nil/true/false, Integer, Float (non-finite -> null, since NaN/Infinity are not
# valid JSON), String, Symbol, Array, Hash. Anything else falls back to its to_s.
# Byte-wise string escaping: bytes >= 0x20 pass through, so UTF-8 multibyte
# sequences (all bytes >= 0x80) are preserved.
module Jamstack
  module JSON
    class << self
      def generate(o)
        s = ""
        emit(o, s)
        s
      end

      private

      def emit(o, s)
        case o
        when nil     then s << 'null'
        when true    then s << 'true'
        when false   then s << 'false'
        when Integer then s << o.to_s
        when Float   then s << (o.finite? ? o.to_s : 'null')
        when String  then estr(o, s)
        when Symbol  then estr(o.to_s, s)
        when Array
          s << '['
          first = true
          o.each { |e| s << ',' unless first; first = false; emit(e, s) }
          s << ']'
        when Hash
          s << '{'
          first = true
          o.each do |k, v|
            s << ',' unless first
            first = false
            estr(k.to_s, s)
            s << ':'
            emit(v, s)
          end
          s << '}'
        else
          estr(o.to_s, s)
        end
      end

      def estr(str, s)
        s << '"'
        str.each_byte do |b|
          case b
          when 34 then s << '\\"'
          when 92 then s << '\\\\'
          when 10 then s << '\\n'
          when 9  then s << '\\t'
          when 13 then s << '\\r'
          else
            s << (b < 0x20 ? format('\\u%04x', b) : b.chr)
          end
        end
        s << '"'
      end
    end
  end
end
