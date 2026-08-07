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

require "active_storage/filename"

class CostQuery::PDF::ExportTimesheetJob < Exports::ExportJob
  self.model = ::CostQuery

  def project
    options[:project]
  end

  def title
    I18n.t("export.timesheet.title")
  end

  private

  def export!
    handle_export_result(export, pdf_report_result)
  end

  def prepare!
    CostQuery::Cache.check
    self.query = CostQuery.build_query(project, query)
    query.name = options[:query_name]
  end

  def pdf_report_result
    content = generate_timesheet
    time = Time.current.strftime("%Y-%m-%d-T-%H-%M-%S")
    export_title = "timesheet-#{time}.pdf"
    ::Exports::Result.new(format: :pdf,
                          title: export_title,
                          mime_type: "application/pdf",
                          content:)
  end

  def generate_timesheet
    generator = ::CostQuery::PDF::TimesheetGenerator.new(query, project)
    generator.generate!
  end
end
