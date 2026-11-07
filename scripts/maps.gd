extends RefCounted
## The hand-made maps on the match lobby grid, easiest first. Each is drawn
## as text, one string per row of cells (each cell is RoomGen.TILE metres):
##   #  wall          c  crate (waist high)       .  floor
##   1-4  spawn spots, in the order players get them (1 and 2 sit in the middle)
##   g k f  gunman / knife / fists
##   G K F  the same, but only with 3 or more players
##   *  where the gun lies at the start (otherwise a normal player holds it)
##   x y  practice dummies (tutorial): x wake at step 1, y at step 3
## `pace` scales enemy speed and attack rate (1.0 = normal).

const RoomGen := preload("res://scripts/room_gen.gd")

const ORDER := ["warmup", "yard", "crossfire", "maze", "gauntlet", "giggles"]
const TUTORIALS := ["tutorial_a", "tutorial_b"]

const ALL := {
	# Tutorial A: free practice. No enemies; the gun lies in the middle.
	"tutorial_a": {
		"name": "TUTORIAL", "level": "FREE PRACTICE", "pace": 1.0,
		"rows": [
			"################",
			"#..............#",
			"#....3.1.2.4...#",
			"#..............#",
			"#..............#",
			"#...##.....c...#",
			"#.......*......#",
			"#..c...........#",
			"#.......##..##.#",
			"#..............#",
			"#....##........#",
			"################",
		],
	},
	# Tutorial B: a training course. Three dummies in a line (x), one by the
	# far wall for the recall (y), then slow real enemies (step 5).
	"tutorial_b": {
		"name": "TRAINING", "level": "TRAINING COURSE", "pace": 0.6, "enemy_group": 3,
		"rows": [
			"################",
			"#..............#",
			"#....3.1.2.4...#",
			"#..............#",
			"#.......*......#",
			"#..c........c..#",
			"#f......x.....f#",
			"#..............#",
			"#.......x......#",
			"#...c......c...#",
			"#.......x......#",
			"#..f.........g.#",
			"#.......y......#",
			"################",
		],
	},
	"warmup": {
		"name": "WARM UP", "level": "SUPER EASY", "pace": 0.75,
		"rows": [
			"################",
			"#..............#",
			"#....3.1.2.4...#",
			"#..............#",
			"#..............#",
			"#...c......c...#",
			"#..............#",
			"#..............#",
			"#..f.......f...#",
			"#......F.......#",
			"#.......f......#",
			"################",
		],
	},
	"yard": {
		"name": "THE YARD", "level": "EASY", "pace": 0.85,
		"rows": [
			"##################",
			"#................#",
			"#.....3.1.2.4....#",
			"#................#",
			"#..c..........c..#",
			"#................#",
			"#...cc....##.....#",
			"#.........#..f...#",
			"#..k......#......#",
			"#.........#..K...#",
			"#....f.......f...#",
			"#...#####...cc...#",
			"#..F..g.......k..#",
			"##################",
		],
	},
	"crossfire": {
		"name": "CROSSFIRE", "level": "MEDIUM", "pace": 1.0,
		"rows": [
			"####################",
			"#..................#",
			"#......3.1.2.4.....#",
			"#..................#",
			"#..##..........##..#",
			"#..##....cc....##..#",
			"###..............###",
			"#g......####......g#",
			"#....k..####..k....#",
			"#..................#",
			"#..##....cc....##..#",
			"#..##..f....f..##..#",
			"#.......K..F.......#",
			"#...k..........k...#",
			"#.G......g.......G.#",
			"####################",
		],
	},
	"maze": {
		"name": "THE MAZE", "level": "HARD", "pace": 1.1,
		"rows": [
			"######################",
			"#....................#",
			"#.......3.1.2.4......#",
			"#....................#",
			"####.######.#####.####",
			"#....#......#...#....#",
			"#.k..#k#.####.#.#..f.#",
			"#....#.#..K...#...#..#",
			"##.###.####.###.#.#.##",
			"#......#..K.#...#.#..#",
			"#.####.#.##.#.###.#..#",
			"#.#..f...#..g..G..#.k#",
			"#.#.####.#.####.###..#",
			"#...#..k.#....#...F..#",
			"#.#.#.####.##.#####..#",
			"#g#....G......f....#g#",
			"######################",
		],
	},
	"gauntlet": {
		"name": "GAUNTLET", "level": "VERY HARD", "pace": 1.25,
		"rows": [
			"########################",
			"#......................#",
			"#.........3.1.2.4......#",
			"#......................#",
			"#..c......c...c......c.#",
			"###.####.######.####.###",
			"#g#.#..#.#....#.#..#.#g#",
			"#...#.k..#.cc.#..k.#...#",
			"#.#.##.###....###.##.#.#",
			"#......................#",
			"#..c..cc...k..k...cc.c.#",
			"#......................#",
			"#.#.##.###....###.##.#.#",
			"#...#.f..#.GG.#..f.#...#",
			"#g#.#..#.#....#.#..#.#g#",
			"###.####.##..##.####.###",
			"#.....k....g.g.....F...#",
			"########################",
		],
	},
	"giggles": {
		"name": "SHITS & GIGGLES", "level": "GOOD LUCK", "pace": 1.45,
		"rows": [
			"########################",
			"#......................#",
			"#.........3.1.2.4......#",
			"#......................#",
			"#...c....c....c....c...#",
			"#......................#",
			"#......................#",
			"#.g...k...g..g...k...g.#",
			"#..c...f...cc...f...c..#",
			"#.k..g....k..k....g..k.#",
			"#......................#",
			"#..g...cc..gg..cc...g..#",
			"#......................#",
			"#.f..k..f..ff..f..k..f.#",
			"#......................#",
			"#.g..G..g..GG..g..G..g.#",
			"#....K....F..F....K....#",
			"########################",
		],
	},
}


static func is_fixed(id: String) -> bool:
	return ALL.has(id)


static func is_tutorial(id: String) -> bool:
	return id in TUTORIALS


static func display_name(id: String) -> String:
	return ALL[id]["name"] if ALL.has(id) else id.to_upper()


## The room for map `id` with this many players.
static func build(id: String, player_count: int) -> RefCounted:
	var m: Dictionary = ALL[id]
	return RoomGen.from_layout(m["rows"], player_count, m["pace"], m.get("enemy_group", 0))
