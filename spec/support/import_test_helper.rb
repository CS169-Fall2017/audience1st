require 'spec_helper'
module ImportTestHelper

  def self.extended(base)
    @@klass = base
  end

  def pretend_uploaded(file,type='text/csv')
    self.stub!(:uploaded_data).and_return IO.read(file)
    self
  end

end
