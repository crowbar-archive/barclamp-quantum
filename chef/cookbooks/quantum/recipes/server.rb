# Copyright 2011 Dell, Inc.
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

include_recipe "quantum::database"
include_recipe "quantum::api_register"
include_recipe "quantum::common_install"

unless node[:quantum][:use_gitrepo]
  quantum_service_name="quantum-server"
  pkgs = [ "quantum-server",
           "quantum-l3-agent",
           "quantum-dhcp-agent",
           "quantum-plugin-openvswitch" ]
  pkgs.each { |p| package p }
  file "/etc/default/quantum-server" do
    action :delete
    notifies :restart, "service[#{quantum_service_name}]"
  end
else
  quantum_service_name="quantum-server"
  quantum_path = "/opt/quantum"
  venv_path = node[:quantum][:use_virtualenv] ? "#{quantum_path}/.venv" : nil
  venv_prefix = node[:quantum][:use_virtualenv] ? ". #{venv_path}/bin/activate &&" : nil

  link_service "quantum" do
    virtualenv venv_path
    bin_name "quantum-server --config-dir /etc/quantum/"
  end
  link_service "quantum-dhcp-agent" do
    virtualenv venv_path
    bin_name "quantum-dhcp-agent --config-dir /etc/quantum/"
  end
  link_service "quantum-l3-agent" do
    virtualenv venv_path
    bin_name "quantum-l3-agent --config-dir /etc/quantum/"
  end
end

env_filter = " AND keystone_config_environment:keystone-config-#{node[:quantum][:keystone_instance]}"
keystones = search(:node, "recipes:keystone\\:\\:server#{env_filter}") || []
if keystones.length > 0
  keystone = keystones[0]
  keystone = node if keystone.name == node.name
else
  keystone = node
end

keystone_address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(keystone, "admin").address if keystone_address.nil?
keystone_token = keystone["keystone"]["service"]["token"]
keystone_service_port = keystone["keystone"]["api"]["service_port"]
keystone_admin_port = keystone["keystone"]["api"]["admin_port"]
keystone_service_tenant = keystone["keystone"]["service"]["tenant"]
keystone_service_user = node["quantum"]["service_user"]
keystone_service_password = node["quantum"]["service_password"]
Chef::Log.info("Keystone server found at #{keystone_address}")

template "/etc/quantum/api-paste.ini" do
  source "api-paste.ini.erb"
  owner "quantum"
  group "root"
  mode "0640"
  variables(
    :keystone_ip_address => keystone_address,
    :keystone_admin_token => keystone_token,
    :keystone_service_port => keystone_service_port,
    :keystone_service_tenant => keystone_service_tenant,
    :keystone_service_user => keystone_service_user,
    :keystone_service_password => keystone_service_password,
    :keystone_admin_port => keystone_admin_port
  )
end

directory "/etc/quantum/plugins/openvswitch/" do
   mode 00775
   owner "quantum"
   action :create
   recursive true
end

template "/etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini" do
  source "ovs_quantum_plugin.ini.erb"
  owner "quantum"
  group "root"
  mode "0640"
  variables(
      :ovs_sql_connection => node[:quantum][:ovs_sql_connection]
  )
end

service "#{quantum_service_name}" do
  supports :status => true, :restart => true
  action :enable
  subscribes :restart, resources("template[/etc/quantum/api-paste.ini]"), :immediately
  subscribes :restart, resources("template[/etc/quantum/plugins/openvswitch/ovs_quantum_plugin.ini]"), :immediately
  subscribes :restart, resources("template[/etc/quantum/quantum.conf]")
end

service "quantum-dhcp-agent" do
  supports :status => true, :restart => true
  action :enable
  subscribes :restart, resources("template[/etc/quantum/quantum.conf]")
end

service "quantum-l3-agent" do
  supports :status => true, :restart => true
  action :enable
  subscribes :restart, resources("template[/etc/quantum/quantum.conf]")
end


include_recipe "quantum::post_install_conf"

node[:quantum][:monitor] = {} if node[:quantum][:monitor].nil?
node[:quantum][:monitor][:svcs] = [] if node[:quantum][:monitor][:svcs].nil?
node[:quantum][:monitor][:svcs] << ["quantum"] if node[:quantum][:monitor][:svcs].empty?
node.save

