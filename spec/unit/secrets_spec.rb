# frozen_string_literal: true

RSpec.describe Ctree::Secrets do
  describe ".secret?" do
    %w[
      OBSERVE_US_API_TOKEN ARTIFACTORY_TOKEN DB_PASSWORD RAILS_SECRET
      AWS_CREDENTIAL_FILE SOME_API_KEY TLS_PRIVATE_KEY passwd_for_db
    ].each do |key|
      it "treats #{key} as secret" do
        expect(described_class.secret?(key)).to be(true)
      end
    end

    %w[INST_DOMAIN FILES_DOMAIN OBSERVE_US_CUSTOMER_ID COMPOSE_PROJECT_NAME DB_PORT].each do |key|
      it "treats #{key} as not secret" do
        expect(described_class.secret?(key)).to be(false)
      end
    end

    it "does not raise on a nil key" do
      expect(described_class.secret?(nil)).to be(false)
    end
  end

  describe ".redact" do
    it "replaces a secret value" do
      expect(described_class.redact("ARTIFACTORY_TOKEN", "cmVmdGtu")).to eq("(hidden)")
    end

    it "passes a non-secret value through" do
      expect(described_class.redact("INST_DOMAIN", "inseng.test")).to eq("inseng.test")
    end
  end

  describe ".pair" do
    it "renders a non-secret as key=value" do
      expect(described_class.pair("INST_DOMAIN", "inseng.test")).to eq("INST_DOMAIN=inseng.test")
    end

    it "renders a secret without its value" do
      expect(described_class.pair("ARTIFACTORY_TOKEN", "cmVmdGtu")).to eq("ARTIFACTORY_TOKEN=(hidden)")
    end

    it "redacts a secret even when the value is nil" do
      expect(described_class.pair("ARTIFACTORY_TOKEN", nil)).to eq("ARTIFACTORY_TOKEN=(hidden)")
    end
  end
end
