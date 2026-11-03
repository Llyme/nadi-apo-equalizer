-- The tests of Equalizer: `nadi-plugin test apo-equalizer`.

local T0 = 1800000000000

local BASS = { preamp = -6, bands = { { f = 60, g = 6, q = 1.41, t = "PK" }, { f = 120, g = 3, q = 1.41, t = "PK" } } }
local OTHER = { preamp = 0, bands = { { f = 1000, g = 0, q = 1.41, t = "PK" } } }
local CURRENT = { preamp = -15, bands = { { f = 10, g = 24, q = 1.41, t = "PK" }, { f = 20000, g = 24, q = 2.99, t = "PK" } } }

local function start()
	return handle({ event = "start", now = T0, settings = {}, open = {} })
end

local function hello(state: any?)
	return handle({ event = "helper", now = T0 + 10, settings = {}, open = {}, data = { type = "hello", apo = true, writable = true, theirs = "theirs.txt", current = CURRENT, devices = { "Speakers" }, state = state } })
end

local function act(a: string, args: any?, now: number?)
	return handle({ event = "action", now = now or T0 + 1000, settings = {}, action = a, args = args or {}, open = { eq = true } })
end

local function find(body, kind, n: number?)
	local seen = 0
	for _, b in body do
		if b.kind == kind then
			seen += 1
			if seen == (n or 1) then
				return b
			end
		end
	end
	return nil
end

local function item(row, kind, n: number?)
	return find(row.items, kind, n)
end

local function whole(out)
	return out.widgets.eq.panel.out.body
end

local function sent(out, cmd)
	for _, h in out.helper or {} do
		if h.cmd == cmd then
			return h
		end
	end
	return nil
end

tests = {}

function tests.asks_its_helper_first()
	local out = start()
	check(sent(out, "hello") ~= nil, "asks the helper what there is")
	eq(out.widgets.eq.idle, true, "idle till it hears")
end

function tests.takes_what_plays_now_and_takes_over()
	start()
	local out = hello(nil)
	local w = out.widgets.eq
	eq(w.peek.text, "-15 dB", "what Equalizer APO plays now, its preamp")
	eq(item(whole(out)[1], "pill").text, "Now", "kept as a preset")
	local ap = sent(out, "apply")
	check(ap ~= nil, "written for Equalizer APO")
	check(ap.text:find("Preamp: %-15 dB") ~= nil, "its preamp")
	check(ap.text:find("Filter 1: ON PK Fc 10 Hz Gain 24 dB Q 1.41", 1, true) ~= nil, "its first band")
	check(ap.text:find("Filter 2: ON PK Fc 20000 Hz Gain 24 dB Q 2.99", 1, true) ~= nil, "its last band")
	check(sent(out, "save") ~= nil, "kept")
	eq(#sent(out, "save").state.order, 2, "Flat, and what played")
end

function tests.preamp_at_hand_and_guarded()
	start()
	hello(nil)
	local out = act("pre_step", { by = 1 })
	eq(out.widgets.eq.peek.text, "-14 dB", "a step up (Clip Guard off at first)")
	-- (Clip Guard on: never above what keeps the loudest band (+24) from clipping)
	out = act("guard")
	check(tonumber((out.widgets.eq.peek.text:gsub(" dB", ""))) <= -23.9, "held under the curve's peak")
	out = act("pre_step", { by = 20 })
	check(tonumber((out.widgets.eq.peek.text:gsub(" dB", ""))) <= -23.9, "and stays there")
end

function tests.edits_are_kept_apart_until_saved()
	start()
	hello(nil)
	local out = act("pre_step", { by = -1 })
	eq(item(whole(out)[1], "pill").dot, true, "edited: marked")
	eq(item(out.widgets.eq.panel.body[1], "button").action, "revert", "Reset at its widget")
	local saved = sent(out, "save").state
	check(saved.drafts["Now"] ~= nil, "a draft kept")
	eq(saved.presets["Now"].preamp, -15, "the preset as it was")
	out = act("revert")
	eq(out.widgets.eq.peek.text, "-15 dB", "reverted: heard as it was")
	out = act("pre_step", { by = -2 })
	out = act("save")
	eq(sent(out, "save").state.presets["Now"].preamp, -17, "saved over it")
	eq(item(out.widgets.eq.panel.body[1], "button"), nil, "nothing to reset: no Reset")
end

function tests.undo_and_redo()
	start()
	hello(nil)
	act("pre_step", { by = -1 })
	act("pre_step", { by = -1 })
	local out = act("undo")
	eq(out.widgets.eq.peek.text, "-16 dB", "one step back")
	out = act("redo")
	eq(out.widgets.eq.peek.text, "-17 dB", "and forward again")
end

function tests.bands_added_dragged_and_typed()
	start()
	hello(nil)
	act("open_window")
	local out = act("band_add", { x = 1000, y = 3 })
	local body = whole(out)
	local curve = find(body, "curve")
	eq(#curve.points, 3, "a third band")
	eq(curve.selected, "2", "picked, in its place by frequency")
	out = act("band_drag", { id = "2", x = 2000, y = 6, done = true }, T0 + 2000)
	local pts = find(whole(out), "curve").points
	eq(pts[2].x, 2000, "moved")
	eq(pts[2].y, 6, "louder")
	local row = whole(out)[3]
	eq(row.kind, "row", "the band picked, under the curve")
	eq(item(row, "seg").value, "PK", "its type")
	out = act("band_hz", { text = "2.5k" })
	eq(find(whole(out), "curve").points[2].x, 2500, "typed")
	out = act("band_type", { value = "LP" })
	check(sent(out, "apply").text:find("LPQ Fc 2500 Hz Q 1.41", 1, true) ~= nil, "a low pass, in Equalizer APO's words")
	out = act("band_remove")
	eq(#find(whole(out), "curve").points, 2, "taken away")
end

function tests.a_layout_and_its_curve()
	start()
	hello(nil)
	act("open_window")
	local out = act("layout:31")
	local curve = find(whole(out), "curve")
	eq(#curve.points, 31, "thirty-one even bands")
	eq(#curve.line, 300, "its curve")
	out = act("flatten")
	local c = find(whole(out), "curve")
	check(math.abs(c.line[60]) < 0.01, "flat: the bands' own curve on its middle")
	check(math.abs(c.ghost[60] - (-15)) < 0.01, "flat: as heard, only the preamp")
end

function tests.speakers_and_mix()
	start()
	hello(nil)
	act("open_window")
	local out = act("speakers")
	check(find(whole(out), "slider", 3) ~= nil, "its speakers shown")
	out = act("spk_d:R", { fraction = 0.1 })
	out = act("mix", { value = "swap" })
	local text = sent(out, "apply").text
	check(text:find("Channel: R\nDelay: 3 ms", 1, true) ~= nil, "the right speaker later")
	check(text:find("Copy: L=R R=L", 1, true) ~= nil, "swapped")
end

function tests.presets_switch_and_keep_their_drafts()
	start()
	hello(nil)
	act("pre_step", { by = -1 })
	local out = act("preset:Flat")
	eq(out.widgets.eq.peek.text, "0 dB", "another put on")
	out = act("preset:Now")
	eq(out.widgets.eq.peek.text, "-16 dB", "back: its draft still there")
end

function tests.state_comes_back()
	start()
	local state = { on = true, presets = { ["Bass Boost"] = BASS, Other = OTHER }, order = { "Other", "Bass Boost" }, current = "Bass Boost", drafts = {}, sets = {} }
	start()
	local out = handle({ event = "helper", now = T0, settings = {}, open = {}, data = { type = "hello", apo = true, writable = true, devices = {}, state = state } })
	eq(item(whole(out)[1], "pill").text, "Bass Boost", "as it was left")
end

function tests.no_equalizer_apo()
	start()
	local out = handle({ event = "helper", now = T0, settings = {}, open = {}, data = { type = "hello", apo = false, devices = {} } })
	eq(out.widgets.eq.peek.text, "No APO", "says so")
	eq(sent(out, "apply"), nil, "writes nothing")
end

function tests.off_hands_equalizer_apo_back()
	start()
	hello(nil)
	local out = act("power")
	check(sent(out, "release") ~= nil, "given back what it read before")
	eq(sent(out, "apply"), nil, "nothing of its own written")
	eq(out.widgets.eq.peek.text, "Off", "says so")
	local small = out.widgets.eq.panel.body
	eq(#small, 1, "at its widget, the switch alone")
	eq(item(small[1], "switch").on, false, "off")
	out = act("pre_step", { by = 1 })
	eq(sent(out, "apply"), nil, "off: nothing written")
	out = act("power")
	check(sent(out, "apply") ~= nil, "on: its own again")
end

function tests.the_preamp_at_its_steps()
	start()
	hello(nil)
	local row = (act("pre_step", { by = 0 })).widgets.eq.panel.body[1]
	eq(#(act("pre_step", { by = 0 })).widgets.eq.panel.body, 1, "at its widget: one line")
	eq(item(row, "slider").range.step, 0.5, "half a dB at first")
	act("open_window")
	local num_ = nil
	for _, b in whole(act("pre_step", { by = 0 })) do
		if b.kind == "row" and item(b, "num") and item(b, "num").action == "step" then
			num_ = item(b, "num")
		end
	end
	check(num_ ~= nil, "its step typed beside the preamp, popped out")
	act("step", { text = "1" })
	local out = act("pre_wheel", { up = true })
	eq(out.widgets.eq.peek.text, "-14 dB", "a whole dB a notch")
	out = act("preamp", { fraction = (-9.7 + 30) / 50 }, T0 + 5000)
	eq(out.widgets.eq.peek.text, "-10 dB", "dragged: at its steps")
end
