# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

require "spec_helper"

RSpec.describe Colors::HexColor do
  let(:color_class) { Data.define(:hexcode).include(described_class) }

  describe "#rgb_colors" do
    context "when hexcode is valid" do
      it "returns an RGB array" do
        expect(color_class.new(hexcode: "#FF69B4").rgb_colors).to eq [255, 105, 180]
      end
    end

    context "when hexcode is too short" do
      it "returns an RGB array, zeroing missing component values" do
        expect(color_class.new(hexcode: "#ff").rgb_colors).to eq [255, 0, 0]
      end
    end

    context "when hexcode is too long" do
      it "returns an RGB array, dropping extra values" do
        expect(color_class.new(hexcode: "#ff3366AA").rgb_colors).to eq [255, 51, 102]
      end
    end

    context "when hexcode is invalid" do
      it "returns an RGB array, zeroing invalid component values" do
        expect(color_class.new(hexcode: "#eeXXcd").rgb_colors).to eq [238, 0, 205]
      end
    end
  end

  describe "#darken" do
    context "when hexcode is valid" do
      it "returns the darkened color's hexcode" do
        expect(color_class.new(hexcode: "#663399").darken(0.5)).to eq "#331a4d"
      end
    end

    context "when hexcode is invalid" do
      it "zeroes missing component values and returns the darkened color's hexcode" do
        expect(color_class.new(hexcode: "#eeXXcd").darken(0.5)).to eq "#770067"
      end
    end
  end

  describe "#lighten" do
    context "when hexcode is valid" do
      it "returns the lightened color's hexcode" do
        expect(color_class.new(hexcode: "#663399").lighten(0.5)).to eq "#b399cc"
      end
    end

    context "when hexcode is invalid" do
      it "zeroes missing component values and returns the darkened color's hexcode" do
        expect(color_class.new(hexcode: "#eeXXcd").lighten(0.5)).to eq "#f780e6"
      end
    end
  end
end
