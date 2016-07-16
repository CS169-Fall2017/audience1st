class ReportsController < ApplicationController

  require 'set'

  before_filter :is_staff_filter

  def index
    # all showdates
    @all_showdates = Showdate.find(:all).sort_by { |s| s.thedate }
    # next showdate
    @next_showdate = Showdate.current_or_next
    # all show names
    @all_shows = Show.find(:all)
    # quick subscription stats
    @subscriptions = Voucher.subscription_vouchers(Time.now.year)
    # list of all special reports
    @special_report_names = Report.subclasses.map { |s| s.underscore.humanize.capitalize }.unshift('Select report...')
  end

  def do_report
    # this is a dispatcher that just redirects to the correct report
    # based on a dropdown menu.
    @report_dates = params[:report_dates]
    @from,@to = Time.range_from_params(@report_dates)
    case params[:rep]
    when /retail/i
      retail
    when /transaction/i
      transaction_details_report
    when /earned/i
      accounting_report
    else
      redirect_with(reports_path, :alert => "Please select a valid report.")
    end
  end

  def advance_sales
    if (params[:shows].blank? ||
        (@shows = params[:shows].map { |s| Show.find_by_id(s) }.flatten).empty?)
      flash[:alert] = "Please select one or more shows."
      redirect_to :action => :index
    end
  end

  def showdate_sales
    entity = Object.const_get(params[:klass])
    render :status => :unprocessable_entity and return unless (entity == Show || entity == Showdate)
    entity = entity.find(params[:id])
    vouchers = entity.vouchers

    sales = Showdate::Sales.new(vouchers.group_by(&:vouchertype),
      entity.revenue_per_seat, entity.total_offered_for_sale)
    render :partial => 'showdate_sales', :locals => { :sales => sales }
  end

  def subscriber_details
    y = (params[:id] || Time.now.year).to_i
    subs = Voucher.subscription_vouchers(y)
    render :partial => 'subscriptions', :object => subs, :locals => {:year => y}
    if params[:download]
      CSV::Writer.generate(output='') do |csv|
        csv << %w[name amount quantity]
        q=0 ; t=0
        subs.each { |s| csv << s ; t += s[1]*s[2] ; q += s[2] }
        csv << ['Total',t,q]
        download_to_excel(output, "subs#{y}")
      end
    end
  end

  def  attendance
    report_name = params[:report_name].to_s.gsub(/\s+/, '_').downcase
    return unless report_subclass = validate_report_type(report_name)
    @report = report_subclass.__send__(:new)
    @args = @report.view_params
    @sublists = EmailList.get_sublists unless EmailList.disabled?
    render :partial => "reports/special_report", :locals => {:name => report_name}
  end

  def create_sublist
    name = params[:sublist_name]
    @error_messages = EmailList.errors unless EmailList.create_sublist(name)
    @sublists = EmailList.get_sublists
    render :partial => 'sublist'
  end

  def run_special
    return unless (klass = validate_report_type params[:report_name])
    @report = klass.__send__(:new, params[:output])
    result = @report.generate_and_postprocess(params) # error!
    return render(:text => (result ? "#{@report.customers.length} matches" : "(Error)")) if request.xhr?

    # HTML render
    return redirect_with(reports_path, :alert => "Errors generating report: #{@report.errors}") unless result

    # Valid, but no results
    return redirect_with(reports_path, :alert => "No matching customers.") if result.empty?
    
    # success
    case params[:commit]
    when /download/i
      @report.create_csv
      download_to_excel(@report.output, @report.filename, false)
    when /display/i
      @customers = @report.customers
      render :template => 'customers/index'
    when /add/i
      l = @report.customers.length
      seg = params[:sublist]
      result = EmailList.add_to_sublist(seg, @report.customers)
      flash[:notice] = "#{result} customers added to sublist '#{seg}'. " <<
        EmailList.errors.to_s
      redirect_to reports_path
    end
  end

  def unfulfilled_orders
    v = Voucher.find(:all,
                     :include => [:customer, :vouchertype, :order],
                     :conditions => 'orders.sold_on IS NOT NULL AND items.fulfillment_needed = 1',
                     :order => "customers.last_name")
    return redirect_with(reports_path, :notice => 'No unfulfilled orders at this time.') if v.empty?
    if params[:csv]
      output = Voucher.to_csv(v)
      download_to_excel(output, 'customers')
    else
      @vouchers = v
      @unique_addresses = v.group_by { |vc| vc.customer.street }.keys.length
    end
  end

  def mark_fulfilled
    i = 0
    flash[:notice] = ''
    params[:voucher].each_pair do |vid,do_update|
      next if do_update.to_i.zero?
      if (v = Voucher.find(:first, :conditions => ['id = ?', vid.to_i]))
        unless v.fulfillment_needed
          flash[:notice] << "Warning: voucher ID #{vid} was already marked fulfilled<br/>"
        end
        v.fulfillment_needed = false
        v.save!
        i += 1
      end
    end
    redirect_to({:action => 'index'}, {:notice =>  "#{i} orders marked fulfilled"})
  end

  private

  def validate_report_type(str)
    klass = str.camelize.constantize
    valid = klass.ancestors.include?(Report) || klass.ancestors.include?(Ruport::Controller)
    redirect_with(reports_path, :alert => "Invalid report name '#{str}'") unless valid
    valid && klass
  end

  def transaction_details_report
    @report = TransactionDetailsReport.run(@from, @to)
    return redirect_with(reports_path, :alert => 'No matching transactions found') if @report.empty?
    case params[:format]
    when /csv/i
      send_data(@report.to_csv,
        :type => (request.user_agent =~ /windows/i ? 'application/vnd.ms-excel' : 'text/csv'),
        :filename => filename_from_dates('transactions', @from, @to, 'csv'))
    when /pdf/i
      send_data(@report.to_pdf,
        :type => 'application/pdf',
        :filename => filename_from_dates('transactions', @from, @to, 'pdf'))
    else
      render :action => 'transaction_details_report'
    end
  end

  def accounting_report
    @account_codes = params[:account_codes]
    options = {:from => @from, :to => @to, :account_codes => @account_codes}
    if params[:format] =~ /csv/i
      content_type = (request.user_agent =~ /windows/i ? 'application/vnd.ms-excel' : 'text/csv')
      send_data(AccountingReport.render_csv(options),
        :type => content_type,
        :filename => filename_from_dates('revenue', @from, @to, 'csv'))
    elsif params[:format] =~ /pdf/i
      send_data(AccountingReport.render_pdf(options),
        :type => 'application/pdf',
        :filename => filename_from_dates('revenue', @from, @to, 'pdf'))
    else
      @report = AccountingReport.render_html(options)
      render :action => 'accounting_report'
    end
  end

  def retail
    @items = RetailItem.find(:all,
      :include => :order,
      :conditions => ['orders.sold_on BETWEEN ? and ?', @from, @to],
      :order => 'orders.sold_on')
    redirect_to({:action => :index},
      {:notice => 'No retail purchases match these criteria.'}) and return if @items.empty?
  end
  
end
