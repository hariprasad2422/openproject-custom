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

RSpec.describe WorkPackageTypes::CopyWorkflowAttributeContract do
  subject { described_class.new }

  context "if the given work package type id exists and has a workflow" do
    let(:wp_type) { create(:type_with_workflow) }
    let(:params) { { copy_workflow_from: wp_type.id.to_s } }

    it "is valid" do
      expect(subject.call(params)).to be_success
    end
  end

  context "if the given work package type id does not exists" do
    let(:params) { { copy_workflow_from: "NO" } }

    it "is invalid" do
      result = subject.call(params)
      expect(result).to be_failure
      expect(result.errors(full: true)[:copy_workflow_from]).to match_array("Type for workflow copy not found.")
    end
  end

  context "if the given work package type id does not have a workflow" do
    let(:wp_type) { create(:type) }
    let(:params) { { copy_workflow_from: wp_type.id.to_s } }

    it "is invalid" do
      result = subject.call(params)
      expect(result).to be_failure
      expect(result.errors(full: true)[:copy_workflow_from]).to match_array("Type for workflow copy has no own workflow.")
    end
  end
end
