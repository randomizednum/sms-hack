.PHONY: install

PREFIX?=/usr/local

install:
	install -m 755 sms-hack.lua $(PREFIX)/bin/sms-hack
