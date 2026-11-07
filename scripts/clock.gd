extends RefCounted
## The game clock: how fast the world runs compared to real time. Slow motion
## sets it below 1 while both players stand still. Enemies, bullets, enemy
## shots, thrown guns and debris multiply their delta by `scale`; the players'
## own movement, aiming and the network never do.

const SLOW := 0.15         ## world speed while both players stand still

static var scale := 1.0
