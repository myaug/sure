# Parses the amount strings a statement extractor may return as text.
#
# Vietnamese statements write 1.234.567 (dot for thousands) and 1.234.567,89;
# English ones write 1,234,567.89. Stripping everything but digits, dots and
# minus signs reads the first as 1.234, off by a factor of a thousand and
# silently, so the separators are interpreted instead.
#
# A lone separator followed by exactly three digits after a non-zero integer part
# is a thousands separator ("1.234" and "1,234" are both 1234): VND carries no
# minor unit and a 3-digit fraction is not a currency convention anywhere else.
module BankStatementAmount
  # Appended to extractor prompts. Vietnamese statements split debits and credits
  # into separate columns and use dd/mm/yyyy, which models otherwise misread.
  LOCALE_HINTS = "If the statement is Vietnamese: dates are dd/mm/yyyy; numbers use dots for thousands (1.234.567) and a comma for decimals; the \"Nợ\"/\"Ghi nợ\"/\"Rút\" column is a debit (negative) and \"Có\"/\"Ghi có\"/\"Gửi\" is a credit (positive); \"Số dư đầu kỳ\" is the opening balance and \"Số dư cuối kỳ\" the closing balance; put the transaction reference (\"Số tham chiếu\"/\"Số CT\"/\"Mã GD\") in the reference field and keep Vietnamese diacritics as written.".freeze

  class << self
    def parse(value)
      return nil if value.nil?
      return value.to_f if value.is_a?(Numeric)

      text = value.to_s.strip
      return nil if text.empty?

      negative = text.start_with?("-", "−") || text.end_with?("-", "−") || (text.start_with?("(") && text.end_with?(")"))
      digits = text.gsub(/[^0-9.,]/, "")
      return nil unless digits.match?(/\d/)

      number = normalize(digits).to_f
      negative ? -number.abs : number
    end

    private
      def normalize(digits)
        last_dot = digits.rindex(".")
        last_comma = digits.rindex(",")

        if last_dot && last_comma
          decimal = last_dot > last_comma ? "." : ","
          thousands = decimal == "." ? "," : "."
          return digits.delete(thousands).tr(decimal, ".")
        end

        separator = last_dot ? "." : (last_comma ? "," : nil)
        return digits if separator.nil?

        parts = digits.split(separator, -1)
        thousands = parts.size > 2 || (parts.last.length == 3 && parts.first.to_i.nonzero?)
        thousands ? parts.join : parts.join(".")
      end
  end
end
