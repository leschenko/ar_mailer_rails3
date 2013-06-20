require 'spec_helper'

describe 'mails quota for period' do

  it 'parse quota options' do
    options = ArMailerRails3::ARSendmail.process_args %w(-q 10 -r 100)
    options[:Quota].should == 10
    options[:Period].should == 100
  end

  it 'parse quota options' do
    options = ArMailerRails3::ARSendmail.process_args %w(-q 10)
    options[:Quota].should == 10
    @mailer = ArMailerRails3::ARSendmail.new(Quota: 2)
    @mailer.period.should == 86400
  end

  it 'don\'t set default quota options' do
    options = ArMailerRails3::ARSendmail.process_args %w()
    options[:Quota].should be_nil
    options[:Period].should be_nil
  end

  it 'default period if quota' do
    @mailer = ArMailerRails3::ARSendmail.new(Quota: 2)
    @mailer.period.should == 86400
  end

  context 'mails with quota' do
    before do
      @mailer = ArMailerRails3::ARSendmail.new(Quota: 2, Period: 5, Once: true)
      FileUtils.rm_f(@mailer.quota_filename)
      @mailer.stub(:find_emails).and_return(Array.new(3))
      @mailer.stub(:deliver) do |emails|
        @mailer.emails_count += emails.length
      end
      @mailer.stub(:cleanup)
    end

    describe '#exceed_quota?' do
      it 'don\'t exceed quota before sending' do
        @mailer.should_not be_exceed_quota
      end

      it 'exceed quota when emails_count greater quota' do
        @mailer.start_period = Time.now.utc.to_i + 2
        @mailer.emails_count = 2
        @mailer.should be_exceed_quota
      end

      it 'don\'t exceed quota when period passed' do
        @mailer.start_period = Time.now.utc.to_i - 100
        @mailer.emails_count = 100
        @mailer.should_not be_exceed_quota
      end
    end

    describe '#available_quota' do
      it 'available_quota before sending' do
        @mailer.available_quota.should == 2
      end

      it 'available_quota before sending' do
        @mailer.emails_count = 2
        @mailer.available_quota.should == 0
      end

      it 'available_quota before sending' do
        @mailer.emails_count = 5
        @mailer.available_quota.should == 0
      end
    end

    it 'send available quota emails' do
      @mailer.run
      @mailer.emails_count.should == 2
    end

    describe 'storing quota stat' do
      it 'read' do
        File.open(@mailer.quota_filename, 'w+') { |f| f.write '123 2' }
        @mailer.fetch_emails_stat
        @mailer.start_period.should == 123
        @mailer.emails_count.should == 2
      end

      it 'write' do
        @mailer.start_period = 123
        @mailer.emails_count = 2
        @mailer.store_emails_stat
        File.read(@mailer.quota_filename).should == '123 2'
      end
    end

    describe 'run with quota' do
      it 'change emails_count' do
        expect { @mailer.run }.to change { @mailer.emails_count }.from(0).to(2)
      end

      it 'store emails_count' do
        expect { @mailer.run }.to change {
          @mailer.fetch_emails_stat
          @mailer.emails_count
        }.from(0).to(2)
      end

      it 'change emails_count' do
        @mailer.emails_count = 10
        @mailer.store_emails_stat
        expect { @mailer.run }.to_not change { @mailer.emails_count }
      end

      it 'don\'t use old emails stat' do
        @mailer.start_period = Time.now.utc.to_i - 100
        @mailer.emails_count = 10
        @mailer.store_emails_stat
        expect { @mailer.run }.to change { @mailer.emails_count }.from(10).to(2)
      end

      it 'use fresh emails stat' do
        @mailer.quota = 4
        @mailer.emails_count = 1
        @mailer.store_emails_stat
        expect { @mailer.run }.to change { @mailer.emails_count }.from(1).to(4)
      end
    end

    it 'run without quota' do
      @mailer.quota = nil
      expect { @mailer.run }.to change { @mailer.emails_count }
    end
  end

end