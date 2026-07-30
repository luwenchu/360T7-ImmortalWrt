mp = Map("openvpn", translate("OpenVPN Server"),
	translate("An easy config OpenVPN Server Web-UI"))

mp:section(SimpleSection).template = "openvpn/openvpn_status"

s = mp:section(TypedSection, "openvpn")
s.anonymous = true
s.addremove = false

s:tab("basic", translate("Base Setting"))

o = s:taboption("basic", Flag, "enabled", translate("Enable"))

proto = s:taboption("basic", Value, "proto", translate("Proto"))
proto:value("tcp4", translate("TCP Server IPv4"))
proto:value("udp4", translate("UDP Server IPv4"))
proto:value("tcp6", translate("TCP Server IPv6"))
proto:value("udp6", translate("UDP Server IPv6"))

port = s:taboption("basic", Value, "port", translate("Port"))
port.datatype = "range(1, 65535)"

remote_port = s:taboption("basic", Value, "remote_port",
	translate("Public Port"))
remote_port.datatype = "range(1, 65535)"
remote_port.default = "8989"
remote_port.rmempty = true
remote_port.description = translate("External port forwarded by the upstream router; leave empty to use the server port")

ddns = s:taboption("basic", Value, "ddns", translate("WAN DDNS or IP"))
ddns.datatype = "string"
ddns.default = "example.com"
ddns.rmempty = false

localnet = s:taboption("basic", Value, "server", translate("Client Network"))
localnet.datatype = "string"
localnet.description = translate("VPN Client Network IP with subnet")

list = s:taboption("basic", DynamicList, "push")
list.title = translate("Client Settings")
list.datatype = "string"
list.description = translate("Set route 192.168.0.0 255.255.255.0 and dhcp-option DNS 192.168.0.1 base on your router")

local o
o = s:taboption("basic", Button, "certificate",
	translate("OpenVPN Client config file"))
o.inputtitle = translate("Download .ovpn file")
o.description = translate("If you are using IOS client, please download this .ovpn file and send it via QQ or Email to your IOS device")
o.inputstyle = "reload"
o.write = function()
	luci.sys.call("sh /etc/openvpn/genovpn.sh >/dev/null 2>&1")
	Download()
end

local o
o = s:taboption("basic", Button, "renew_certificate",
	translate("Renew OpenVPN certificate files"))
o.inputtitle = translate("Renew")
o.inputstyle = "reload"
o.write = function()
	luci.sys.call("sh /etc/openvpn/renewcert.sh >/dev/null 2>&1 &")
end

s:tab("code", translate("Special Code"))

local conf = "/etc/openvpn-addon.conf"
local NXFS = require "nixio.fs"
o = s:taboption("code", TextValue, "conf")
o.description = translate("(!)Special Code you know that add in to client .ovpn file")
o.rows = 13
o.wrap = "off"
o.cfgvalue = function()
	return NXFS.readfile(conf) or ""
end
o.write = function(self, section, value)
	NXFS.writefile(conf, value:gsub("\r\n", "\n"))
end

local pid = luci.util.exec("/usr/bin/pgrep openvpn")

function openvpn_process_status()
	local status = "OpenVPN is not running now "

	if pid ~= "" then
		status = "OpenVPN is running with the PID " .. pid
	end

	local status_table = { status = status }
	return { pid = status_table }
end

function Download()
	local file = nixio.open("/tmp/my.ovpn", "r")
	if not file then
		return
	end

	luci.http.header("Content-Disposition", 'attachment; filename="my.ovpn"')
	luci.http.prepare_content("application/octet-stream")
	while true do
		local chunk = file:read(nixio.const.buffersize)
		if not chunk or #chunk == 0 then
			break
		end
		luci.http.write(chunk)
	end
	file:close()
	NXFS.unlink("/tmp/my.ovpn")
	luci.http.close()
end

function mp.on_after_commit()
	local uci = require("luci.model.uci").cursor()
	local server_port = uci:get("openvpn", "myvpn", "port")
	local server_proto = uci:get("openvpn", "myvpn", "proto") or "udp4"

	if server_port and server_port:match("^%d+$") then
		uci:set("firewall", "openvpn", "dest_port", server_port)
		uci:set("firewall", "openvpn", "proto",
			server_proto:match("^tcp") and "tcp" or "udp")
		uci:commit("firewall")
		luci.sys.call("/etc/init.d/firewall restart >/dev/null 2>&1")
	end

	luci.sys.call("/etc/init.d/openvpn restart >/dev/null 2>&1")
end

return mp
