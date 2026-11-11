#!/usr/bin/env python3
"""Static v18 mapping/artwork compatibility audit; run from any platform."""
from pathlib import Path
import plistlib, re, struct, subprocess, tempfile, hashlib
p=Path(__file__).resolve().parents[1]
resource=p/'Resources'
with (resource/'Nintendo3DS-Info.plist').open('rb') as f: info=plistlib.load(f)
with (resource/'Keyboard-Mappings.plist').open('rb') as f: keyboard=plistlib.load(f)
with (resource/'Controller-Mappings.plist').open('rb') as f: mappings=plistlib.load(f)
with (resource/'Controller-Preferences.plist').open('rb') as f: artwork=plistlib.load(f)
h=(p/'OE3DSSystemResponder.h').read_text()
m=(p/'OE3DSSystemResponder.m').read_text()
assert info['CFBundleVersion']=='24' and info['CFBundleShortVersionString']=='1.24'
controls=info['OEGenericControlNamesKey']
assert len(controls)==22 and len(set(controls))==22
block=h.split('typedef NS_ENUM(NSUInteger, OE3DSButton) {',1)[1].split('};',1)[0]
identifiers=re.findall(r'\bOE3DSButton[A-Za-z]+\b',block)
assert identifiers[:-1]==controls and identifiers[-1]=='OE3DSButtonCount'
assert 'OE3DSButtonHome' not in controls and 'OE3DSButtonHome' not in m
assert controls[12:15]==['OE3DSButtonStart','OE3DSButtonSelect','OE3DSButtonCirclePadUp']
assert set(artwork['OEControllerKeyPositionKey'])==set(controls)
assert set(artwork['OEControllerKeyPositionKey'])==set(controls)
assert set(keyboard)==set(controls)
assert not any('OE3DSButtonHome' in str(x) for x in (info,mappings,artwork,keyboard))
assert len(set(keyboard.values()))==len(keyboard)
assert all(set(group).issubset(set(controls)) for group in mappings.values())
assert any('OE3DSButtonStart' in group for group in mappings.values())
assert 'didPushNDSButton:' in m and 'didReleaseNDSButton:' in m
assert 'didChange3DSAnalogAxis:' in m and 'didChange3DSExtraButton:' in m
assert 'didTouchScreenPoint:' in m and 'didReleaseTouch' in m
assert 'if(key == OE3DSButtonStart) return 10;' in m
assert 'if(key == OE3DSButtonSelect) return 11;' in m
assert 'OE3DSButtonZL?0:1' in m
assert 'v24 responder class loaded' in m
assert 'OE3DSSystemController' in (p/'OE3DSSystemController.swift').read_text()
def png_dimensions(path):
    data=path.read_bytes()
    assert data[:8]==b'\x89PNG\r\n\x1a\n'
    assert data[12:16]==b'IHDR'
    return struct.unpack('>II',data[16:24])
assert png_dimensions(resource/'controller_3ds@2x.png')==(744,851)
assert png_dimensions(resource/'controller_3ds_mask@2x.png')==(744,851)
assert png_dimensions(p/'Artwork-References/Original-3DS-Controller.png')==(744,799)
assert png_dimensions(resource/'icon.png')==(30,32)
# The working v15 artwork/presets are frozen by this release contract.
sha15={
    'Resources/controller_3ds@2x.png': '04c93015aa4e22b3731dd70b48a0932156bff544b1d50001770d1e874cd96d37',
    'Resources/controller_3ds_mask@2x.png': '8b76270d5bdfbab5060c34165b3b1d176cc42a207119bda7c3e33ca531fa2c53',
    'Artwork-References/Original-3DS-Controller.png': 'e022a0cc27e5eac80f4cb40a00e913590521971a0ef1919fffef76e13b5c304c',
    'Resources/Keyboard-Mappings.plist': 'd3c1f58ec57a0cee7955c2dc60190b496b8693aed211f5f852ac4a304dd828e6',
    'Resources/Controller-Mappings.plist': 'e25d3749e1927584b6c76e587c54f77dbcc7ad24d76357f495e13c862c464bcf',
}
for relative, expected in sha15.items():
    assert hashlib.sha256((p/relative).read_bytes()).hexdigest()==expected, relative

for coord in artwork['OEControllerKeyPositionKey'].values():
    x,y=(float(x) for x in re.findall(r'-?\d+(?:\.\d+)?',coord))
    assert 0<=x<372 and 0<=y<425.5,(x,y)
# Compile the responder's actual pure-C key/axis helpers with stand-in typedefs.
start=m.index('static NSInteger OE3DSNDSButtonForKey(')
end=m.index('@implementation OE3DSSystemResponder',start)
helpers=m[start:end]
source='''#include <assert.h>
#include <stdbool.h>
#include <math.h>
typedef unsigned long NSUInteger;
typedef long NSInteger;
typedef bool BOOL;
''' + re.sub(r'\s*//[^\n]*', '', block).replace('OE3DSButtonUp,','enum OE3DSButton { OE3DSButtonUp,',1).replace('OE3DSButtonCount','OE3DSButtonCount };',1) + helpers + '''int main(void) {
    assert(OE3DSNDSButtonForKey(OE3DSButtonUp)==0);
    assert(OE3DSNDSButtonForKey(OE3DSButtonA)==4);
    assert(OE3DSNDSButtonForKey(OE3DSButtonStart)==10);
    assert(OE3DSNDSButtonForKey(OE3DSButtonSelect)==11);
    assert(OE3DSNDSButtonForKey(OE3DSButtonZL)==-1);
    assert(OE3DSIsAnalog(OE3DSButtonCirclePadUp));
    assert(!OE3DSIsAnalog(OE3DSButtonStart));
    assert(OE3DSAxisForKey(OE3DSButtonCirclePadLeft)==0);
    assert(OE3DSAxisForKey(OE3DSButtonCirclePadUp)==1);
    assert(OE3DSAxisForKey(OE3DSButtonCStickLeft)==2);
    assert(OE3DSAxisForKey(OE3DSButtonCStickUp)==3);
    assert(OE3DSDirectionForKey(OE3DSButtonCirclePadUp)==-1);
    assert(OE3DSDirectionForKey(OE3DSButtonCStickRight)==1);
    return 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    cc=Path(tmp)/'mapping.c'; exe=Path(tmp)/'mapping'
    cc.write_text(source)
    subprocess.run(['cc','-std=c11','-Werror','-Wall','-Wextra',str(cc),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
# The project must refresh SDK-specific Swift frameworks before compiling Swift.
proj=(p/'Nintendo3DSSystemPlugin.xcodeproj/project.pbxproj').read_text()
assert proj.index('A00000000000000000000070 /* Rebuild OpenEmu Swift frameworks for this Xcode SDK */,') < proj.index('A00000000000000000000013 /* Sources */,')
assert 'prepare-openemu-frameworks.sh' in proj
phase=(p/'prepare-openemu-frameworks.sh').read_text()
assert '-scheme OpenEmuSystem' in phase and 'MACOSX_DEPLOYMENT_TARGET=12.0' in phase
assert 'OpenEmuBase OpenEmuSystem' in phase and 'SDKROOT' in phase
assert '/usr/bin/ditto' in phase and 'SDK_PATH' in phase
print('V24 22-CONTROL + ARTWORK + XCODE SDK + COMPILED MAPPING AUDIT PASS')

assert (p/'tools/source-lock.py').is_file()
assert (p/'DEVELOPER_HANDOFF.md').is_file()
assert (p/'tools/capture-source-revisions.py').is_file()
assert (p/'tools/run-source-checks.py').is_file()
assert 'v24 mapped' in m and 'v24 init complete' in m
print('V22 HANDOFF + PROVENANCE AUDIT PASS')
