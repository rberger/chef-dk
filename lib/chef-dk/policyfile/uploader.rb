#
# Copyright:: Copyright (c) 2014 Chef Software Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/cookbook_uploader'
require 'chef-dk/policyfile/read_cookbook_for_compat_mode_upload'

require 'chef-dk/ui'

module ChefDK
  module Policyfile
    class Uploader

      LockedCookbookForUpload = Struct.new(:cookbook, :lock)

      class UploadReport

        attr_reader :reused_cbs
        attr_reader :uploaded_cbs
        attr_reader :ui

        def initialize(reused_cbs: [], uploaded_cbs: [], ui: nil)
          @reused_cbs = reused_cbs
          @uploaded_cbs = uploaded_cbs
          @ui = ui

          @justify_name_width = nil
          @justify_version_width = nil
        end

        def show
          reused_cbs.each do |cb_with_lock|
            ui.msg("Using    #{describe_lock(cb_with_lock.lock, justify_name_width, justify_version_width)}")
          end

          uploaded_cbs.each do |cb_with_lock|
            ui.msg("Uploaded #{describe_lock(cb_with_lock.lock, justify_name_width, justify_version_width)}")
          end
        end

        def justify_name_width
          @justify_name_width ||= cookbook_names.map {|e| e.size }.max
        end

        def justify_version_width
          @justify_version_width ||= cookbook_version_numbers.map {|e| e.size }.max
        end

        def cookbook_names
          (reused_cbs + uploaded_cbs).map { |e| e.lock.name }
        end

        def cookbook_version_numbers
          (reused_cbs + uploaded_cbs).map { |e| e.lock.version }
        end

        def describe_lock(lock, justify_name_width, justify_version_width)
          "#{lock.name.ljust(justify_name_width)} #{lock.version.ljust(justify_version_width)} (#{lock.identifier[0,8]})"
        end

      end

      COMPAT_MODE_DATA_BAG_NAME = "policyfiles".freeze

      attr_reader :policyfile_lock
      attr_reader :policy_group
      attr_reader :http_client
      attr_reader :ui

      def initialize(policyfile_lock, policy_group, ui: nil, http_client: nil)
        @policyfile_lock = policyfile_lock
        @policy_group = policy_group
        @http_client = http_client
        @ui = ui || UI.null

        @cookbook_versions_for_policy = nil
      end

      def upload
        ui.msg("WARN: Uploading policy to policy group #{policy_group} in compatibility mode")

        upload_cookbooks
        data_bag_create
        data_bag_item_create
      end

      def data_bag_create
        http_client.post("data", {"name" => COMPAT_MODE_DATA_BAG_NAME})
      rescue Net::HTTPServerException => e
        raise e unless e.response.code == "409"
      end

      def data_bag_item_create
        policy_id = "#{policyfile_lock.name}-#{policy_group}"
        lock_data = policyfile_lock.to_lock.dup

        lock_data["id"] = policy_id

        data_item = {
          "id" => policy_id,
          "name" => "data_bag_item_#{COMPAT_MODE_DATA_BAG_NAME}_#{policy_id}",
          "data_bag" => COMPAT_MODE_DATA_BAG_NAME,
          "raw_data" => lock_data,
          # we'd prefer to leave this out, but the "compatibility mode"
          # implementation in chef-client relies on magical class inflation
          "json_class" => "Chef::DataBagItem"
        }

        upload_lockfile_as_data_bag_item(policy_id, data_item)
        ui.msg("Policy uploaded as data bag item #{COMPAT_MODE_DATA_BAG_NAME}/#{policy_id}")
        true
      end

      def uploader
        # TODO: uploader runs cookbook validation; we want to do this at a different time.
        @uploader ||= Chef::CookbookUploader.new(cookbook_versions_to_upload, :rest => http_client)
      end

      def cookbook_versions_to_upload
        cookbook_versions_for_policy.inject([]) do |versions_to_upload, cookbook_with_lock|
          cb = cookbook_with_lock.cookbook
          versions_to_upload << cb unless remote_already_has_cookbook?(cb)
          versions_to_upload
        end
      end

      def remote_already_has_cookbook?(cookbook)
        return false unless existing_cookbook_on_remote.key?(cookbook.name.to_s)

        existing_cookbook_on_remote[cookbook.name.to_s]["versions"].any? do |cookbook_info|
          cookbook_info["version"] == cookbook.version
        end
      end

      def existing_cookbook_on_remote
        @existing_cookbook_on_remote ||= http_client.get('cookbooks?num_versions=all')
      end

      # An Array of Chef::CookbookVersion objects representing the full set that
      # the policyfile lock requires.
      def cookbook_versions_for_policy
        return @cookbook_versions_for_policy if @cookbook_versions_for_policy
        policyfile_lock.validate_cookbooks!
        @cookbook_versions_for_policy = policyfile_lock.cookbook_locks.map do |name, lock|
          cb = ReadCookbookForCompatModeUpload.load(name, lock.dotted_decimal_identifier, lock.cookbook_path)
          LockedCookbookForUpload.new(cb, lock)
        end
      end

      private

      def upload_cookbooks
        ui.msg("WARN: Uploading cookbooks using semver compat mode")

        uploader.upload_cookbooks

        reused_cbs, uploaded_cbs = cookbook_versions_for_policy.partition do |cb_with_lock|
          remote_already_has_cookbook?(cb_with_lock.cookbook)
        end

        UploadReport.new(reused_cbs: reused_cbs, uploaded_cbs: uploaded_cbs, ui: ui).show

        true
      end

      def upload_lockfile_as_data_bag_item(policy_id, data_item)
        http_client.put("data/#{COMPAT_MODE_DATA_BAG_NAME}/#{policy_id}", data_item)
      rescue Net::HTTPServerException => e
        raise e unless e.response.code == "404"
        http_client.post("data/#{COMPAT_MODE_DATA_BAG_NAME}", data_item)
      end
    end
  end
end
