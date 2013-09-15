require 'spec_helper'

describe 'mails quota for period' do

  let(:smtp_config_path) { File.expand_path('../smtp_test_config.yml', __FILE__) }

  context 'parse options' do
    it 'smtp_config_path empty by default' do
      options = ArMailerRails3::ARSendmail.process_args %w()
      options[:smtp_config_path].should be_nil
    end

    it 'smtp config per domain' do
      options = ArMailerRails3::ARSendmail.process_args ['--smtp_config_path', smtp_config_path]
      options[:smtp_config_path].should == smtp_config_path
    end
  end

  context 'mails with domain' do
    before do
      @mailer = ArMailerRails3::ARSendmail.new(smtp_config_path: smtp_config_path, Once: true)
      @mailer.stub(:cleanup)
      @mailer.stub(:deliver)
    end

    describe 'domain rotation' do
      before do
        @mailer.stub(:find_emails).and_return([])
      end

      it 'pick up domains' do
        @mailer.domains.should == %w(vf eg)
      end

      it 'rotate domains' do
        @mailer.run
        @mailer.current_domain.should == 'vf'
        @mailer.run
        @mailer.current_domain.should == 'eg'
      end

      it 'smtp settings by domain' do
        @mailer.current_domain = 'eg'
        @mailer.current_domain.should == 'eg'
      end
    end

    describe '#find_emails' do
      it 'find emails with domain' do
        ArMailerRails3::ARSendmail.stub(:email_class).and_return(CustomEmailClass)
        CustomEmailClass.should_receive(:find).with(:all, hash_including({domain: 'vf'})).and_return([])
        @mailer.run
      end
    end

    describe '#smtp_settings' do
      before do
        @mailer.stub(:find_emails).and_return([])
      end

      it 'fetch smtp config for domain' do
        @mailer.current_domain = 'vf'
        @mailer.smtp_settings[:domain].should == 'vf.com'
      end

      it 'fetch smtp config for domain' do
        @mailer.current_domain = nil
        proc { @mailer.smtp_settings }.should raise_exception
      end
    end
  end

end
