require "rails_helper"

RSpec.describe User, type: :model do
  describe "associations" do
    it { is_expected.to have_many(:dashboards).dependent(:destroy) }
  end

  describe "Devise modules" do
    it "includes database_authenticatable, registerable, recoverable, rememberable, validatable" do
      expect(User.devise_modules).to include(
        :database_authenticatable,
        :registerable,
        :recoverable,
        :rememberable,
        :validatable
      )
    end
  end

  describe "validations" do
    subject { build(:user) }

    it "is valid with correct attributes" do
      expect(subject).to be_valid
    end

    it "requires email" do
      subject.email = ""
      expect(subject).not_to be_valid
      expect(subject.errors[:email]).to be_present
    end

    it "rejects malformed email" do
      subject.email = "not-an-email"
      expect(subject).not_to be_valid
      expect(subject.errors[:email]).to be_present
    end

    it "enforces unique email" do
      create(:user, email: "duplicate@example.com")
      user = build(:user, email: "duplicate@example.com")
      expect(user).not_to be_valid
      expect(user.errors[:email]).to be_present
    end

    it "treats email uniqueness as case-insensitive" do
      create(:user, email: "mixed@example.com")
      user = build(:user, email: "MIXED@example.com")
      expect(user).not_to be_valid
    end

    it "requires a password on creation" do
      user = build(:user, password: nil, password_confirmation: nil)
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it "rejects passwords shorter than Devise minimum" do
      user = build(:user, password: "123", password_confirmation: "123")
      expect(user).not_to be_valid
      expect(user.errors[:password]).to be_present
    end

    it "rejects mismatching password confirmation" do
      user = build(:user, password: "password123", password_confirmation: "different")
      expect(user).not_to be_valid
      expect(user.errors[:password_confirmation]).to be_present
    end
  end

  describe "password hashing" do
    it "stores an encrypted password, not the plaintext" do
      user = create(:user, password: "password123", password_confirmation: "password123")
      expect(user.encrypted_password).to be_present
      expect(user.encrypted_password).not_to eq("password123")
    end

    it "authenticates with the correct password" do
      user = create(:user, password: "password123", password_confirmation: "password123")
      expect(user.valid_password?("password123")).to be true
      expect(user.valid_password?("wrong-password")).to be false
    end
  end

  describe "cascading deletes" do
    it "destroys associated dashboards when the user is destroyed" do
      user = create(:user)
      create(:dashboard, user: user)
      create(:dashboard, user: user)

      expect { user.destroy }.to change { Dashboard.count }.by(-2)
    end
  end
end
