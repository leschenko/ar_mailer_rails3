require 'ar_mailer_rails3'
require 'ar_mailer_rails3/ar_sendmail'

class Hash
  def symbolize_keys
    dup.symbolize_keys!
  end

  def symbolize_keys!
    keys.each do |key|
      self[(key.to_sym rescue key) || key] = delete(key)
    end
    self
  end
end


class CustomEmailClass
  class << self
    def where(*cond)
      self
    end

    def limit(l)
      self
    end

    def length
      0
    end

    def first(n=1)
      []
    end
  end
end