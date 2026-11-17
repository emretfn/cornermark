# Cornermark

A local macOS menu-bar app that captures screenshots and screen recordings, and edits both without anything leaving the Mac.

## Recording sound

**Microphone track**:
The sound a recording took from the microphone, kept as its own file beside the video and never changed after recording.
_Avoid_: mic audio, voice track

**System audio track**:
The sound the Mac played during a recording, kept as its own file beside the video.
_Avoid_: desktop audio, computer sound

**Voice cleanup**:
A recording's edit that makes the Microphone track clearer in preview and export, made of the cleanup steps below in a fixed order, leaving the recorded file untouched.
_Avoid_: noise filter, audio enhancement, denoise

**Low cut**:
The Voice cleanup step that removes sound below a chosen frequency, such as hum and air conditioning.
_Avoid_: high-pass, rumble filter

**Noise removal**:
The Voice cleanup step that separates speech from steady background noise, at a chosen strength.
_Avoid_: denoise, voice isolation, noise suppression

**Noise gate**:
The Voice cleanup step that silences the microphone while its sound stays below a chosen threshold.
_Avoid_: gate, expander

**Leveling**:
The Voice cleanup step that evens out loud and soft speech and brings the whole Microphone track to one fixed loudness.
_Avoid_: normalize, compressor, auto gain

**Track level**:
How loud a sound track plays in the finished video, applied after Voice cleanup.
_Avoid_: volume, gain
