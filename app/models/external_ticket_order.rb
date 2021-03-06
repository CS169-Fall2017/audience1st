class ExternalTicketOrder
  # when pulled from external will-call list, populate these fields:
  attr_accessor :last_name, :first_name, :qty, :ticket_offer, :order_key
  # when try to process, fill in these fields:
  attr_accessor :status, :vouchers

  def initialize(args={})
    args.each_pair { |var,val| self.instance_variable_set("@#{var}".to_sym,val) }
    @vouchers = []
    @status = "(not processed)"
  end
  
  def to_s
    "#{@last_name},#{@first_name}: " +
      sprintf("%2d of <%s> (order key %s) => %s",
              qty, ticket_offer.vouchertype.name, order_key, status)
  end
    
  def process!(args={})
    # once processed, the 'vouchers' attribute will contain a list of the
    # voucher objects created; you can find the customer by deferencing
    # the customer attribute of each voucher
    raise(ArgumentError,"Order not tagged with valid TicketOffer") unless
      @ticket_offer.kind_of?(TicketOffer)
    if (@order_key.to_i != 0 &&
        (v=Voucher.find_by_external_key(@order_key.to_i)))
      @status = "Order ID #{@order_key} already entered as voucher id #{v.id} "
      if v.customer.kind_of?(Customer)
        @status << " (belongs to #{v.customer.id} #{v.customer.full_name})"
      else
        @status << " (doesn't appear to belong to any customer)"
      end
      return nil
    end
    begin
      c = Customer.find_or_create!(
        Customer.new(:first_name => @first_name,:last_name => @last_name))
    rescue Exception => e
      @status << "Error creating/finding customer:\n" << e.message
      return nil
    end
    unless args[:verify_only]
      @qty.times do
        v = Voucher.new_from_vouchertype(ticket_offer.vouchertype,
          :showdate => ticket_offer.showdate)
        v.external_key = order_key.to_i
        v.processed_by_id = Customer.boxoffice_daemon.id
        @vouchers << v
      end
      c.vouchers += @vouchers
      c.save
      @status = sprintf("%d voucher%s added", @qty, (@qty==1 ? "" : "s"))
    end
    return c
  end
end
