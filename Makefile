# Build zBackup bash script

TARGET = zbackup
SOURCE = zbackup.sh

RM = rm -f
INSTALL = /usr/bin/install -c

prefix = /usr/local
bindir = $(prefix)/bin

all:

install: all
	mkdir -p $(bindir)
	$(INSTALL) $(SOURCE) $(bindir)/$(TARGET)

.PHONY: all install
