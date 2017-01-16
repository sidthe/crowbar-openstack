#
# Copyright 2016 SUSE Linux GmbH
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
# Cookbook Name:: magnum
# Recipe:: api
#
include_recipe "apache2"
include_recipe "apache2::mod_wsgi"

package "openstack-magnum-api"

keystone_settings = KeystoneHelper.keystone_settings(node, :magnum)
network_settings = MagnumHelper.network_settings(node)

magnum_port = node[:magnum][:api][:bind_port]
magnum_protocol = node[:magnum][:api][:protocol]

bind_port = network_settings[:api][:bind_port]
bind_host = network_settings[:api][:bind_host]

ha_enabled = node[:magnum][:ha][:enabled]

my_admin_host = CrowbarHelper.get_host_for_admin_url(node, ha_enabled)
my_public_host = CrowbarHelper.get_host_for_public_url(
  node, node[:magnum][:api][:protocol] == "https", ha_enabled)

if node[:magnum][:api][:protocol] == "https"
  ssl_setup "setting up ssl for magnum" do
    generate_certs node[:magnum][:ssl][:generate_certs]
    certfile node[:magnum][:ssl][:certfile]
    keyfile node[:magnum][:ssl][:keyfile]
    group node[:magnum][:group]
    fqdn node[:fqdn]
    cert_required node[:magnum][:ssl][:cert_required]
    ca_certs node[:magnum][:ssl][:ca_certs]
  end
end

crowbar_pacemaker_sync_mark "wait-magnum_register"

register_auth_hash = { user: keystone_settings["admin_user"],
                       password: keystone_settings["admin_password"],
                       tenant: keystone_settings["admin_tenant"] }

keystone_register "magnum api wakeup keystone" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  action :wakeup
end

keystone_register "register magnum user" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  user_name keystone_settings["service_user"]
  user_password keystone_settings["service_password"]
  tenant_name keystone_settings["service_tenant"]
  action :add_user
end

keystone_register "give magnum user access" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  user_name keystone_settings["service_user"]
  tenant_name keystone_settings["service_tenant"]
  role_name "admin"
  action :add_access
end

keystone_register "register magnum service" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  service_name "magnum"
  service_type "container-infra"
  service_description "Container Infrastructure Management Service"
  action :add_service
end

keystone_register "register magnum endpoint" do
  protocol keystone_settings["protocol"]
  insecure keystone_settings["insecure"]
  host keystone_settings["internal_url_host"]
  port keystone_settings["admin_port"]
  auth register_auth_hash
  endpoint_service "magnum"
  endpoint_region keystone_settings["endpoint_region"]
  endpoint_publicURL "#{magnum_protocol}://"\
                     "#{my_public_host}:#{magnum_port}/v1"
  endpoint_adminURL "#{magnum_protocol}://"\
                    "#{my_admin_host}:#{magnum_port}/v1"
  endpoint_internalURL "#{magnum_protocol}://"\
                       "#{my_admin_host}:#{magnum_port}/v1"
  action :add_endpoint_template
end

crowbar_pacemaker_sync_mark "create-magnum_register"

node.normal[:apache][:listen_ports_crowbar] ||= {}
node.normal[:apache][:listen_ports_crowbar][:magnum] = { plain: [bind_port] }

crowbar_openstack_wsgi "WSGI entry for magnum-api" do
  bind_host bind_host
  bind_port bind_port
  daemon_process "magnum-api"
  user node[:magnum][:user]
  group node[:magnum][:group]
  script_alias "/srv/www/magnum-api/app.wsgi"
  pass_authorization true
  limit_request_body 114688
  ssl_enable node[:magnum][:api][:protocol] == "https"
  ssl_certfile node[:magnum][:ssl][:certfile]
  ssl_keyfile node[:magnum][:ssl][:keyfile]
  if node[:magnum][:ssl][:cert_required]
    ssl_cacert node[:magnum][:ssl][:ca_certs]
  end
end

apache_site "magnum-api.conf" do
  enable true
end
