//
//   Copyright (C) 2007 by sinamas <sinamas at users.sourceforge.net>
//
//   This program is free software; you can redistribute it and/or modify
//   it under the terms of the GNU General Public License version 2 as
//   published by the Free Software Foundation.
//
//   This program is distributed in the hope that it will be useful,
//   but WITHOUT ANY WARRANTY; without even the implied warranty of
//   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//   GNU General Public License version 2 for more details.
//
//   You should have received a copy of the GNU General Public License
//   version 2 along with this program; if not, write to the
//   Free Software Foundation, Inc.,
//   51 Franklin St, Fifth Floor, Boston, MA  02110-1301, USA.
//

#include "file/file.h"
#include "file/memfile.h"
#include "gambatte.h"
#include "cpu.h"
#include "initstate.h"
#include "savestate.h"
#include "state_osd_elements.h"
#include "statesaver.h"

#include <cstring>
#include <sstream>

using namespace gambatte;

namespace {

std::string to_string(int i) {
	std::stringstream ss;
	ss << i;
	return ss.str();
}

std::string statePath(std::string const &basePath, int stateNo) {
	return basePath + '_' + to_string(stateNo) + ".gqs";
}

}

struct GB::Priv {
	CPU cpu;
	int stateNo;
	unsigned loadflags;

	Priv() : stateNo(1), loadflags(0) {}
};

GB::GB() : p_(new Priv) {}

GB::~GB() {
	if (p_->cpu.loaded())
		p_->cpu.saveSavedata();

	delete p_;
}

std::ptrdiff_t GB::runFor(gambatte::uint_least32_t *const videoBuf, std::ptrdiff_t const pitch,
                          gambatte::uint_least32_t *const soundBuf, std::size_t &samples) {
	if (!p_->cpu.loaded()) {
		samples = 0;
		return -1;
	}

	p_->cpu.setVideoBuffer(videoBuf, pitch);
	p_->cpu.setSoundBuffer(soundBuf);

	long const cyclesSinceBlit = p_->cpu.runFor(samples * 2);
	samples = p_->cpu.fillSoundBuffer();
	return cyclesSinceBlit >= 0
	     ? static_cast<std::ptrdiff_t>(samples) - (cyclesSinceBlit >> 1)
	     : cyclesSinceBlit;
}

void GB::reset() {
	if (p_->cpu.loaded()) {
		p_->cpu.saveSavedata();

		SaveState state;
		p_->cpu.setStatePtrs(state);
		setInitState(state, p_->cpu.isCgb(), p_->loadflags & GBA_CGB);
		p_->cpu.loadState(state);
		p_->cpu.loadSavedata();
	}
}

void GB::setInputGetter(InputGetter *getInput) {
	p_->cpu.setInputGetter(getInput);
}

void GB::setSaveDir(std::string const &sdir) {
	p_->cpu.setSaveDir(sdir);
}

LoadRes GB::load(const void *rom,
                 size_t size,
                 std::string const &filename,
                 unsigned const flags) {
	MemFile file(rom, size);
	return load(file, filename, flags);
}

LoadRes GB::load(std::string const &filename, unsigned const flags) {
	transfer_ptr<File> file = newFileInstance(filename);
	return load(*file, filename, flags);
}

LoadRes GB::load(File &file, std::string const &filename, unsigned const flags) {
	if (p_->cpu.loaded())
		p_->cpu.saveSavedata();

	LoadRes const loadres = p_->cpu.load(file, filename,
	                                     flags & FORCE_DMG,
	                                     flags & MULTICART_COMPAT);
	if (loadres == LOADRES_OK) {
		SaveState state;
		p_->cpu.setStatePtrs(state);
		p_->loadflags = flags;
		setInitState(state, p_->cpu.isCgb(), flags & GBA_CGB);
		p_->cpu.loadState(state);
		p_->cpu.loadSavedata();

		p_->stateNo = 1;
		p_->cpu.setOsdElement(transfer_ptr<OsdElement>());
	}

	return loadres;
}

bool GB::isCgb() const {
	return p_->cpu.isCgb();
}

bool GB::isLoaded() const {
	return p_->cpu.loaded();
}

void GB::saveSavedata() {
	if (p_->cpu.loaded())
		p_->cpu.saveSavedata();
}

void GB::setCgbColorCorrection(int optNum) {
	p_->cpu.setCgbColorCorrection(optNum);
}

void GB::setDmgPaletteColor(int palNum, int colorNum, unsigned long rgb32) {
	p_->cpu.setDmgPaletteColor(palNum, colorNum, rgb32);
}

//> OpenEmu
bool GB::serializeState(std::ostream &stream) {
    if (p_->cpu.loaded()) {
        SaveState state;
        p_->cpu.setStatePtrs(state);
        p_->cpu.saveState(state);
        return StateSaver::serializeState(state, stream);
    }

    return false;
}

bool GB::deserializeState(std::istream &stream) {
    if (p_->cpu.loaded()) {
        p_->cpu.saveSavedata();

        SaveState state;
        p_->cpu.setStatePtrs(state);

        if (StateSaver::deserializeState(state, stream)) {
            p_->cpu.loadState(state);
            return true;
        }
    }

    return false;
}

uint8_t GB::busRead8(uint16_t address) const {
    return p_->cpu.busRead8(address);
}

unsigned char * GB::memoryArea(MemoryArea area, std::size_t &size) const {
    if (!p_->cpu.loaded()) {
        size = 0;
        return 0;
    }
    return p_->cpu.memoryArea(area, size);
}

void GB::busWritePlain(uint16_t address, uint8_t value) {
    if (p_->cpu.loaded())
        p_->cpu.busWritePlain(address, value);
}

//< OpenEmu
bool GB::loadState(std::string const &filepath) {
	if (p_->cpu.loaded()) {
		p_->cpu.saveSavedata();

		SaveState state = SaveState();
		p_->cpu.setStatePtrs(state);

		if (StateSaver::loadState(state, filepath)) {
			p_->cpu.loadState(state);
			return true;
		}
	}

	return false;
}

bool GB::saveState(gambatte::uint_least32_t const *videoBuf, std::ptrdiff_t pitch) {
	if (saveState(videoBuf, pitch, statePath(p_->cpu.saveBasePath(), p_->stateNo))) {
		p_->cpu.setOsdElement(newStateSavedOsdElement(p_->stateNo));
		return true;
	}

	return false;
}

bool GB::loadState() {
	if (loadState(statePath(p_->cpu.saveBasePath(), p_->stateNo))) {
		p_->cpu.setOsdElement(newStateLoadedOsdElement(p_->stateNo));
		return true;
	}

	return false;
}

bool GB::saveState(gambatte::uint_least32_t const *videoBuf, std::ptrdiff_t pitch,
                   std::string const &filepath) {
	if (p_->cpu.loaded()) {
		SaveState state;
		p_->cpu.setStatePtrs(state);
		p_->cpu.saveState(state);
		return StateSaver::saveState(state, videoBuf, pitch, filepath);
	}

	return false;
}

void GB::selectState(int n) {
	n -= (n / 10) * 10;
	p_->stateNo = n < 0 ? n + 10 : n;

	if (p_->cpu.loaded()) {
		std::string const &path = statePath(p_->cpu.saveBasePath(), p_->stateNo);
		p_->cpu.setOsdElement(newSaveStateOsdElement(path, p_->stateNo));
	}
}

int GB::currentState() const { return p_->stateNo; }

std::string const GB::romTitle() const {
	if (p_->cpu.loaded()) {
		char title[0x11];
		std::memcpy(title, p_->cpu.romTitle(), 0x10);
		title[title[0xF] & 0x80 ? 0xF : 0x10] = '\0';
		return std::string(title);
	}

	return std::string();
}

PakInfo const GB::pakInfo() const { return p_->cpu.pakInfo(p_->loadflags & MULTICART_COMPAT); }

void GB::setGameGenie(std::string const &codes) {
	p_->cpu.setGameGenie(codes);
}

void GB::setGameShark(std::string const &codes) {
	p_->cpu.setGameShark(codes);
}
