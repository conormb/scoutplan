# frozen_string_literal: true

require "rails_helper"

RSpec.describe UnitMembership, type: :model do
  it "has a valid factory" do
    expect(FactoryBot.build(:unit_membership)).to be_valid
  end

  it "has a secure token" do
    expect(FactoryBot.create(:unit_membership).token).not_to be_nil
  end

  describe "validations" do
    it "prevents duplicates" do
      example = FactoryBot.create(:unit_membership)
      expect(FactoryBot.build(:unit_membership, unit: example.unit, user: example.user)).not_to be_valid
    end

    it "requires a status" do
      expect(FactoryBot.build(:unit_membership, status: nil)).not_to be_valid
    end
  end

  describe "methods" do
    before do
      @member = FactoryBot.create(:unit_membership)
    end

    it "includes self in family" do
      expect(@member.family).to include(@member)
    end

    it "returns a time zone" do
      expect(@member.time_zone).to eq("Eastern Time (US & Canada)")
    end
  end

  describe "family method" do
    before do
      @member = FactoryBot.create(:unit_membership)
      @child1 = FactoryBot.create(:unit_membership, unit: @member.unit)
      @child2 = FactoryBot.create(:unit_membership, unit: @member.unit)
      MemberRelationship.create(parent_unit_membership: @member, child_unit_membership: @child1)
      MemberRelationship.create(parent_unit_membership: @member, child_unit_membership: @child2)
    end

    it "returns correct number of family members" do
      expect(@member.family.count).to eq(3)
    end

    it "prepends self to family" do
      expect(@member.family.count).to eq(3)
      expect(@member.family(include_self: :prepend).first).to eq(@member)
    end

    it "appends self to family" do
      expect(@member.family.count).to eq(3)
      expect(@member.family(include_self: :append).last).to eq(@member)
    end

    it "default appends" do
      expect(@member.family.count).to eq(3)
      expect(@member.family.last).to eq(@member)
    end

    it "omits self" do
      expect(@member.family(include_self: false).count).to eq(2)
    end

    it "returns family for child member" do
      expect(@child1.family.count).to eq(3)
      expect(@child1.family).to include(@member)
    end

    it "returns family for parent member" do
      expect(@member.family(include_self: :prepend)).to include(@child1, @child2)
    end

    it "returns family for parent member with self prepended" do
      expect(@member.family(include_self: :prepend).first).to eq(@member)
    end
  end

  describe "create" do
    it "when user already exists" do
      user = FactoryBot.create(:user)
      unit = FactoryBot.create(:unit)
      member = unit.unit_memberships.create!(user: user)
      expect(member).to be_valid
    end
  end
end
