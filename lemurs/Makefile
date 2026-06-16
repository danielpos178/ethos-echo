.PHONY: install

LEMURS_DIR = /etc/lemurs
PIXMAPS_DIR = /usr/share/pixmaps

install:
	install -Dm644 config.toml                      $(LEMURS_DIR)/config.toml
	install -Dm644 xsetup.sh                         $(LEMURS_DIR)/xsetup.sh
	install -Dm644 lemurs.service                    $(PIXMAPS_DIR)/lemurs.service
	install -Dm644 lemurs.pam                        /etc/pam.d/lemurs
	install -Dm644 ../dwm-logo-bordered.png          $(PIXMAPS_DIR)/dwm-gossamer-logo.png
