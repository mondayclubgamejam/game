extends RefCounted
## The game clock: how fast the world runs compared to real time. Slow motion
## sets it below 1 while every living player stands still. Enemies, bullets,
## enemy shots, thrown guns, debris and the players' movement multiply their
## delta by `scale`; mouse aiming and the network never do. The host decides;
## every other player follows the decision it sends with the enemy updates.

const SLOW := 0.15         ## world speed while both players stand still

static var scale := 1.0
