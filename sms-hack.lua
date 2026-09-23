#!/usr/bin/luajit

--[[
Copyright 2026 Çınar Karaaslan

Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED “AS IS” AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
]]

local autocli = require("autocli")
local lfs = require("lfs")
local pdu = require("pdu")
local md5 = require("md5")
local GLib = require("lgi").GLib
local dbus = require("dbus_proxy")

local usage = [[
Usage: sms-hack [option]...

-h, --help      print this help message
--dir <dir>     use <dir> instead of ~/sms-dir for saving messages
-m <idx>        use modem <idx> (default 0)
-t <timeout>    set timeout to <timeout> (default 5)
]]

local opts = autocli.parse_opts(usage, arg)
if opts["-h"] then
	io.stderr:write(usage)
	os.exit(0)
end

local modem_n = opts["-m"] and assert(tonumber(opts["-m"], "invalid modem index")) or 0
local sms_dir = opts["--dir"] or os.getenv("HOME") .. "/sms-dir"
local timeout = opts["-t"] and assert(tonumber(opts["-t"]), "invalid timeout") or 5

if lfs.attributes(sms_dir, "mode") ~= "directory" then
	assert(lfs.mkdir(sms_dir), "couldn't create directory " .. sms_dir)
end 

--Functions to simplify coloring text.
local function color(red, green, blue)
	local n = 30 + red * 1 + green * 2 + blue * 4
	return function (s)
		return "\x1b[" .. n .. "m" .. s .. "\x1b[0m"
	end
end

function bold(s)
	return "\x1b[1m" .. s .. "\x1b[0m"
end

local red = color(1, 0, 0)
local green = color(0, 1, 0)
local blue = color(0, 0, 1)

local clear = "\x1b[2J\x1b[1;1H"

--Constants for ModemManager.
local mm_pref = "org.freedesktop.ModemManager1"
local mm_path = "/org/freedesktop/ModemManager1"

--DBus proxies.
local Messaging = dbus.Proxy:new({
	bus = dbus.Bus.SYSTEM,
	name = mm_pref,
	interface = mm_pref .. ".Modem.Messaging",
	path = mm_path .. "/Modem/" .. modem_n
})

local Modem = dbus.Proxy:new({
	bus = dbus.Bus.SYSTEM,
	name = mm_pref,
	interface = mm_pref .. ".Modem",
	path = mm_path .. "/Modem/" .. modem_n
})

--List of sms to be displayed to the user.
local sms_list = {}

local mm_sms_list = Messaging:List()

io.write(clear)
for _, v in ipairs(mm_sms_list) do
	io.write("Got sms ", bold(blue(v)), " from ModemManager\n")
end

for _, v in ipairs(mm_sms_list) do
	local sms = dbus.Proxy:new({
		bus = dbus.Bus.SYSTEM,
		name = mm_pref,
		interface = mm_pref .. ".Sms",
		path = v
	})

	table.insert(sms_list, {
		text = sms.Text,
		sender = sms.Number,
		time = sms.Timestamp
	})
end

io.write("Would you like to query modem storage for sms?\n[Y]es/[n]o: ")
io.flush()

local response = io.read("*l")
local modem_query
if response == "" or response:lower() == "y" then
	modem_query = true
elseif response == "n" then
	modem_query = false
else
	io.write("Abort.\n")
	os.exit(1)
end

local function prompt_next()
	io.write("[N]ext: ")
	io.flush()

	local response = io.read("*l")
	if response ~= "" and response ~= "n" then
		io.write("Assuming next.\n")
	end
end

local function send_at_coms(commands)
	if #commands == 0 then return {} end

	io.write(clear)
	for _, command in ipairs(commands) do
		io.write(bold(blue(command)), "\n")
	end
	io.write("Do you want to execute the command(s) above?\n[Y]es/[n]o/[v]iew outputs: ")
	io.flush()

	local response = io.read("*l")
	local view = false
	if response == "n" then return false
	elseif response == "v" then
		view = true
	elseif response ~= "" and response ~= "y" then
		io.write("Assuming no.\n")
		return false
	end

	local t = {}
	for i, command in ipairs(commands) do
		t[i] = Modem:Command(command, timeout)
		if view then
			io.write(clear, blue(command), "\n", bold(t[i]), "\n")
			prompt_next()
		end
	end
	return t
end

local function send_at_com(command)
	local t = send_at_coms({command})
	if not t then return false end

	return t[1]
end

local function parse_cpms_response(response)
	local part = response:match("^%+CPMS: ([^%s]+)%s*$")
	if not part then return false end

	local t_orig, t_dict = {}, {}
	for storage, used, max in part:gmatch('"(..)",(%d+),(%d+)') do
		local used = assert(tonumber(used), "invalid AT+CPMS response")
		local max = assert(tonumber(max), "invalid AT+CPMS response")

		table.insert(t_orig, { storage = storage, used = used, max = max })
		t_dict[storage] = { used = used, max = max }
	end

	assert(#t_orig == 3, "invalid AT+CPMS response")

	return t_orig, t_dict
end

local function make_iso_date(date)
	local year = tonumber(date.year)
	local month = tonumber(date.month)
	local day = tonumber(date.day)
	local hour = tonumber(date.hour)
	local minute = tonumber(date.minute)
	local second = tonumber(date.second)

	year = year > 50 and 1900 + year or 2000 + year

	if
		year and month and day and
		hour and minute and second
	then
		return string.format(
			"%.2d-%.2d-%.2dT%.2d:%.2d:%.2d",
			year, month, day,
			hour, minute, second
		)
	end
	return "0000-00-00T00:00:00"
end

local function hex_to_byteseq(hex)
	if #hex % 2 ~= 0 then return nil end

	local byteseq = ""
	for i = 2, #hex, 2 do
		byteseq = byteseq .. string.char(tonumber(hex:sub(i-1, i), 16))
	end

	return byteseq
end

--Query the modem directly via AT commands to receive SMS texts.
local orig_storages, storages_dict
if modem_query then
	local progress = true
	local storages_str = send_at_com("AT+CPMS?")
	if not storages_str then progress = false end

	if progress then
		orig_storages, storages_dict = parse_cpms_response(storages_str)
		if not orig_storages then progress = false end
	end

	local outputs = {}
	if progress then
		for storage, t in pairs(storages_dict) do
			local responses
			if t.used > 0 then
				local com = 'AT+CPMS="%s","%s","%s"'
				local coms = { com:format(storage, storage, storage) }
				for i = 0, t.used - 1 do
					coms[i+2] = "AT+CMGR=" .. i
				end

				responses = send_at_coms(coms)
			end

			local failed = false
			if responses then
				for i = 2, #responses do
					local response = responses[i]
					local sms_i = i - 2
					local pdu_hex = response:match("^%+CMGR: [^\n]+\n(%x+)%s*$")
					local pdu_str = pdu_hex and hex_to_byteseq(pdu_hex)
					if pdu_str then
						local suc, sms = pcall(pdu.parse, pdu_str)
						if suc then
							table.insert(sms_list, {
								text = sms.text,
								sender = sms.sender,
								time = make_iso_date(sms.time)
							})
						else
							io.write("Failed parsing SMS " .. sms_i .. "@" .. storage, "\n")
							prompt_next()
							failed = true
						end
					else
						io.write("Failed retrieving SMS " .. sms_i .. "@" .. storage, "\n")
						failed = true
					end
				end
			end

			if failed then prompt_next() end
		end
	end

	if progress then
		local args = {}
		for i, v in ipairs(orig_storages) do
			args[i] = v.storage
		end
		local com = 'AT+CPMS="%s","%s","%s"'
		send_at_com(com:format((table.unpack or unpack)(args)))
	end
end

local sms_dict = {}

for _, v in ipairs(sms_list) do
	local md5sum = md5.sumhexa(v.text)
	local name = v.time .. "##" .. v.sender .. "##" .. md5sum

	sms_dict[name] = v
end

local function str_compar(s1, s2)
	local minlen = math.min(#s1, #s2)
	for i = 1, minlen do
		local c1 = s1:sub(i, i):byte()
		local c2 = s2:sub(i, i):byte()
		if c1 < c2 then return true
		elseif c1 > c2 then return false end
	end
	if #s1 < #s2 then return true end
	return false
end

local filenames = {}
for k in pairs(sms_dict) do
	table.insert(filenames, k)
end

table.sort(filenames, str_compar)

for _, filenm in ipairs(filenames) do
	local sms = sms_dict[filenm]
	io.write(clear, bold("Sender: "), sms.sender, "\n")
	io.write(bold("Date: "), sms.time, "\n")
	io.write(bold("Text:"), "\n", sms.text, "\n")
	prompt_next()
end

io.write("Save sms to filesystem?\n[Y]es/[a]bort: ")
io.flush()

local response = io.read("*l")
if response == "a" then
	io.write("Abort.\n")
	os.exit(0)
elseif response ~= "" and response:lower() ~= "y" then
	io.write("Abort.\n")
	os.exit(1)
end

for filenm, sms in pairs(sms_dict) do
	local filedir = sms_dir .. "/" .. filenm
	local f = io.open(filedir, "r")
	if f then
		io.write("File already exists\n")
		f:close()
	else
		f = io.open(filedir, "w")
		f:write(sms.text)
		f:flush()
		f:close()
	end
end

if #mm_sms_list == 0 then
	io.write("(no sms objects to delete)\n")
else
	for _, v in ipairs(mm_sms_list) do
		io.write(bold(blue(v)), "\n")
	end
end
io.write("Delete the sms objects above?\n[Y]es/[n]o: ")
io.flush()

local response = io.read("*l")
if response == "" or response:lower() == "y" then
	for _, v in ipairs(mm_sms_list) do
		Messaging:Delete(v)
	end
elseif response ~= "n" then
	io.write("Abort.\n")
	os.exit(1)
end


if modem_query and orig_storages then
	local coms = {}
	for storage, t in pairs(storages_dict) do
		if t.used > 0 then
			local args = {}
			local com = 'AT+CPMS="%s","%s","%s"'
			table.insert(coms, com:format(storage, storage, storage))
			table.insert(coms, "AT+CMGD=0,4")
		end
	end
	send_at_coms(coms)

	--Restore back to normal.
	local args = {}
	for i, v in ipairs(orig_storages) do
		args[i] = v.storage
	end
	local com = 'AT+CPMS="%s","%s","%s"'
	send_at_com(com:format((table.unpack or unpack)(args)))	
end

io.write("sms maintenance complete!\n")
