/*
	TODO:
	- [RETEST] move round timer
	- add *DEAD* to names (and remove if invalid)
	- cvar toggle if dead can communicate with alive
	- [SEPARATE PLUGIN] add spectator info (health, armor, ammo)
	- (advanced?) teamplay support (with team names)
	- (?) buy menus and zones(?)
	- (?) lives system
	- (?) spectator system on the side
	
	- rewrite to amx1.9+
	- api
*/

#include <amxmisc>
#include <amxmodx>
#include <engine>
#include <fakemeta>
#include <fun>
#include <hamsandwich>
#include <hl>

#define PLUGIN "HL Round Mode"
#define AUTHOR "rtxa, brokenphilip"

#define VERSION "0.2"

#pragma semicolon 1

#define MAX_PLAYERS 32

// CRecharge
// CWallHealth
#define M_IJUICE 62 // 248/4

new const NULL_SOUND[] = "common/null.wav";

new const RND_START_SOUND[] = "fvox/bell.wav";

new const SND_VOX_COUNT[][] = {
	"common/null.wav",
	"fvox/one.wav",
	"fvox/two.wav",
	"fvox/three.wav",
	"fvox/four.wav",
	"fvox/five.wav",
	"fvox/six.wav",
	"fvox/seven.wav",
	"fvox/eight.wav",
	"fvox/nine.wav",
	"fvox/ten.wav"
};

// TaskIDs
enum (+= 100) {
	TASK_FIRSTROUND = 9902,
	TASK_ROUNDPRESTART,
	TASK_ROUNDSTART,
	TASK_ROUNDEND,
	TASK_FREEZEPERIOD,
	TASK_SENDTOSPEC,
	TASK_ROUNDTIMER
};

// because player can't be send to spectator instantly when he connects, player is gonna be alive for a thousandth of a second,
// so that can mess with counting functions for players and make rounds never end.
// to fix it, we need to make those functions ignore those players and all will be fine.
new gHasReallyJoined[MAX_PLAYERS + 1];

// players list
new gPlayers[MAX_PLAYERS];
new gPlayersAlive[MAX_PLAYERS];

// count
new gNumPlayers;
new gNumPlayersAlive;
//new gNumHumans; // alives
//new gNumZombies; // alives

// gamerules
new bool:gRoundStarted;

// timers in seconds
new gCountDown;
new gRoundTime;

// freeze period
new gFreezeTime;
new Float:gSpeedBeforeFreeze[MAX_PLAYERS + 1];

// hud sync handles
new gRoundTimeHudSync;

// cvars
new gCvarFirstRoundTime;
new gCvarCountdownTime;
new gCvarRoundTime;
new gCvarFreezeTime;

// game mode name that should be displayed in server browser
/*public Forward_GameDesc() {
	new szGameDesc[32];
	formatex(szGameDesc, 31, "%s %s", PLUGIN, VERSION);
	forward_return(FMV_STRING, szGameDesc);
	return FMRES_SUPERCEDE;
}*/

public plugin_precache() {
	// TODO: adujst for teamplay
	/*if (get_global_float(GL_teamplay) < 1.0)
		set_fail_state("Not in teamplay mode! Check that ^"mp_teamplay^" value is correct.");

	if (__count_teams() != 2)
		set_fail_state("Only 2 teams are required! Check that ^"mp_teamplay^" value is correct.");

	// precache models from mp_teamlist
	PrecacheTeamList();
	*/
	// round cvars
	gCvarFirstRoundTime = register_cvar("hlrm_firstroundtime", "30.0", FCVAR_SERVER);
	gCvarCountdownTime = register_cvar("hlrm_countdowntime", "11.0", FCVAR_SERVER);
	gCvarRoundTime = register_cvar("hlrm_roundtime", "60", FCVAR_SERVER);
	gCvarFreezeTime = register_cvar("hlrm_freezetime", "2.0", FCVAR_SERVER);
}

public plugin_init() {
	register_plugin(PLUGIN, VERSION, AUTHOR);
	
	RegisterHam(Ham_Killed, "player", "FwPlayerPostKilled", true);
	RegisterHam(Ham_Spawn, "player", "FwPlayerPreSpawn");
	
	//register_forward(FM_GetGameDescription, "Forward_GameDesc");
	
	register_concmd("hlrm_restart", "CmdRoundRestart", ADMIN_BAN);
	register_clcmd("spectate", "CmdSpectate");
	
	gRoundTimeHudSync = CreateHudSyncObj();
	
	// countdown for start the first round.
	gCountDown = get_pcvar_num(gCvarFirstRoundTime);
	FirstRoundCountdown();
}

public FirstRoundCountdown() {
	gCountDown--;
	client_print(0, print_center, "Starting game in %i", gCountDown);

	if (gCountDown == 0) {
		RoundPreStart();
		return;
	}
	set_task(1.0, "FirstRoundCountdown", TASK_FIRSTROUND);
}

public RoundPreStart() {
	gRoundStarted = false;

	// remove tasks to avoid overlap
	remove_task(TASK_FIRSTROUND);
	remove_task(TASK_ROUNDPRESTART);
	remove_task(TASK_ROUNDSTART);
	remove_task(TASK_FREEZEPERIOD);
	remove_task(TASK_ROUNDTIMER);

	// stop countdown sound
	Speak(0, NULL_SOUND);
	client_cmd(0, "mp3 stop");

	// reset map stuff
	ResetMap();

	// get players count
	hlrm_get_players(gPlayers, gNumPlayers);

	// to all players...
	new player;
	for (new i; i < gNumPlayers; i++) {
		player = gPlayers[i];
		// TODO: teamplay
		//SetHuman(player, false);
		if (hl_get_user_spectator(player))
			hlrm_set_user_spectator(player, false);
		else
			hlrm_user_spawn(player);
	}

	// after freeze period, start with infection countdown
	SetAllGodMode(true);
	StartFreezePeriod();
}

public RoundStartCountDown() {
	if (gCountDown == 20) {
		//Speak(0, SND_ROUND_START);
		//PlaySound(0, SND_VOX_20SECREMAIN);
		//PlayMp3(0, ROUND_AMBIENCE[random(sizeof ROUND_AMBIENCE)]);
	} else if (gCountDown <= 10 && gCountDown > 0) {
		Speak(0, SND_VOX_COUNT[gCountDown]);
	} else if (gCountDown <= 0) {
		RoundStart();
		return;
	}
	client_print(0, print_center, "Immunity ends in %i", gCountDown);

	gCountDown--;

	set_task(1.0, "RoundStartCountDown", TASK_ROUNDPRESTART);
}

public RoundStart() {
	SetAllGodMode(false);
	// clean center msgs
	client_print(0, print_center, "");

	Speak(0, RND_START_SOUND);

	gRoundStarted = true;

	// set round time
	StartRoundTimer(get_pcvar_num(gCvarRoundTime));
}

public RoundEnd() {
	gRoundStarted = false;

	/*
	// TODO: teamplay
	hlrm_get_team_alives(gNumHumans, HUMAN_TEAMID);
	hlrm_get_team_alives(gNumZombies, ZOMBIE_TEAMID);

	reimplement for teamplay
	if (gNumHumans > 0 && !gNumZombies) { // humans win
		client_print(0, print_center, "%l", "ROUND_HUMANSWIN");
		PlaySound(0, SND_ROUND_WIN_HUMAN[random(sizeof SND_ROUND_WIN_HUMAN)]);
	} else if (gNumZombies > 0 && !gNumHumans) { // zombies win
		client_print(0, print_center, "%l", "ROUND_ZOMBIESWIN");
		PlaySound(0, SND_ROUND_WIN_ZOMBI[random(sizeof SND_ROUND_WIN_ZOMBI)]);
	} else { // draw
		client_print(0, print_center, "%l", "ROUND_DRAW");
		PlaySound(0, SND_ROUND_DRAW[random(sizeof SND_ROUND_DRAW)]);
	}*/
	
	Speak(0, RND_START_SOUND);
	
	hlrm_get_players_alive(gPlayersAlive, gNumPlayersAlive);
	if (gNumPlayersAlive < 1 || gNumPlayersAlive > 1)
		client_print(0, print_center, "Draw!");
		
	else {
		new client = gPlayersAlive[0];
		new frags = get_user_frags(gPlayersAlive[0]) + 1000;
		new deaths = hl_get_user_deaths(client);
		new team = hl_get_user_team(client);
		
		new szName[33];
		get_user_name(client, szName, charsmax(szName));
		client_print(0, print_center, "%s won!", szName);
		
		set_user_frags(client, frags);
		
		ScoreInfo(client, frags ,deaths, team);
	}

	// call for a new round
	set_task(5.0, "RoundPreStart", TASK_ROUNDPRESTART);
}

ScoreInfo(client, frags, deaths, team) {
	static scoreinfo;
	if(!scoreinfo)
		scoreinfo = get_user_msgid("ScoreInfo");

	message_begin(MSG_ALL, scoreinfo);
	write_byte(client);
	write_short(frags);
	write_short(deaths);
	write_short(0);
	write_short(team);
	message_end();

}

public CheckGameStatus() {
	if (!gRoundStarted || task_exists(TASK_ROUNDEND))
		return;

	// TODO: teamplay
	/*hlrm_get_team_alives(gNumHumans, HUMAN_TEAMID);
	hlrm_get_team_alives(gNumZombies, ZOMBIE_TEAMID);*/
	hlrm_get_players_alive(gPlayersAlive, gNumPlayersAlive);

	// finish round when:
	// in teamplay, less than 1 player on all but one team
	// in dm, less than 2 players
	if (gNumPlayersAlive < 2)
		set_task(0.1, "RoundEnd", TASK_ROUNDEND);
}

public client_putinserver(id) {
	gHasReallyJoined[id] = false;
	set_task(0.1, "TaskPutInServer", id);
}

// Some things have to be delayed to be able to work, I explain you why for some.
public TaskPutInServer(id) {
	// TODO: teamplay
	//hl_set_teamnames(id, fmt("%l", "TEAMNAME_HUMANS"), fmt("%l", "TEAMNAME_ZOMBIES")); // message isn't received by the client at that moment
	hl_set_user_spectator(id, true); // bots can't be send to spec, they're invalid in putinserver. Also, it cause issues with scoreboard on real clients.
	gHasReallyJoined[id] = true;
}

public client_remove(id) {
	CheckGameStatus();
}

public client_kill(id) {
	return PLUGIN_HANDLED; // block kill cmd
}

public FwPlayerPreSpawn(id) {
	// if player has to spec, don't let him spawn...
	if (task_exists(TASK_SENDTOSPEC + id))
		return HAM_SUPERCEDE;
	return HAM_IGNORED;
}

public FwPlayerPostKilled(victim, attacker) {
	// send victim to spec
	set_task(3.0, "SendToSpec", victim + TASK_SENDTOSPEC);

	CheckGameStatus();

	return HAM_IGNORED;
}

public SendToSpec(taskid) {
	new id = taskid - TASK_SENDTOSPEC;
	if (!is_user_alive(id) || is_user_bot(id))
		hl_set_user_spectator(id, true);
}

public StartFreezePeriod() {
	for (new i; i < gNumPlayers; i++) {
		FreezePlayer(gPlayers[i]);
	}
	gFreezeTime = get_pcvar_num(gCvarFreezeTime);
	TaskFreezePeriod();
}

public TaskFreezePeriod() {
	if (gFreezeTime <= 0) {
		hlrm_get_players(gPlayers, gNumPlayers);
		for (new i; i < gNumPlayers; i++) {
			FreezePlayer(gPlayers[i], false);
		}
		// countdown for start round
		gCountDown = get_pcvar_num(gCvarCountdownTime);
		RoundStartCountDown();
		return;
	}
	client_print(0, print_center, "Unfrozen in %i", gFreezeTime);

	gFreezeTime--;

	set_task(1.0, "TaskFreezePeriod", TASK_FREEZEPERIOD);
}

FreezePlayer(id, freeze = true) {
	if (freeze) {
		gSpeedBeforeFreeze[id] = get_user_maxspeed(id);
		set_user_maxspeed(id, 1.0);
	} else {
		set_user_maxspeed(id, gSpeedBeforeFreeze[id]);
	}
}

StartRoundTimer(seconds) {
	gRoundTime = seconds;
	RoundTimerThink();
	set_task(1.0, "RoundTimerThink", TASK_ROUNDTIMER, _, _, "b");
}

public RoundTimerThink() {
	ShowRoundTimer();
	if (gRoundStarted) {
		if (gRoundTime > 0)
			gRoundTime--;
		else
			RoundEnd();
	}
}

public ShowRoundTimer() {
	new r, g, b;
	if (gRoundTime >= 30) { // green color
		r = 0;
		g = 255;
		b = 0;
	} else if (gRoundTime >= 10) { // brown color
		r = 250;
		g = 170;
		b = 0;
	} else { // red color
		r = 255;
		g = 50;
		b = 50;
	}

	// OLD - r,g,b, 0.01, -0.1
	set_hudmessage(r, g, b, -1.0, 0.1, 0, 0.01, gRoundStarted ? 600.0 : 1.0, 0.2, 0.2);
	ShowSyncHudMsg(0, gRoundTimeHudSync, "%i:%02i", gRoundTime / 60, gRoundTime % 60);
}

public CmdRoundRestart(id, level, cid) {
	if (!cmd_access(id, level, cid, 0))
		return PLUGIN_HANDLED;
	RoundPreStart();
	return PLUGIN_HANDLED;
}

public CmdSpectate(id) {
	return PLUGIN_HANDLED;
}

hlrm_get_players(players[MAX_PLAYERS], &num) {
	num = 0;
	for (new id = 1; id <= 32; id++) {
		if (!is_user_hltv(id) && is_user_connected(id) && gHasReallyJoined[id]) {
			players[num++] = id;
		}
	}
}

hlrm_get_players_alive(players[MAX_PLAYERS], &num) {
	num = 0;
	for (new id = 1; id <= 32; id++) {
		if (is_user_alive(id) && gHasReallyJoined[id]) {
			players[num++] = id;
		}
	}
}

// TODO: teamplay
/*
// get_players() by team give false values sometimes, use this.
hlrm_get_team_alives(&teamAlives, teamindex) {
	teamAlives = 0;
	for (new id = 1; id <= MaxClients; id++)
		if (is_user_alive(id) && hl_get_user_team(id) == teamindex && gHasReallyJoined[id])
			teamAlives++;
}*/

hlrm_set_user_spectator(client, bool:spectator = true) {
	if (!spectator)
		remove_task(client + TASK_SENDTOSPEC); // remove task to let him respawn
	hl_set_user_spectator(client, spectator);
}

hlrm_user_spawn(client) {
	remove_task(client + TASK_SENDTOSPEC); // if you dont remove this, he will not respawn
	hl_user_spawn(client);
}

ResetMap() {
	ClearCorpses();
	ClearField();
	RespawnItems();
	ResetFuncChargers();
}

ClearCorpses() {
	new ent;
	while ((ent = find_ent_by_class(ent, "bodyque")))
		set_pev(ent, pev_effects, EF_NODRAW);
}

// this will clean entities like tripmines, satchels, etc...
ClearField() {
	static const fieldEnts[][] = { "bolt", "monster_snark", "monster_satchel", "monster_tripmine", "beam", "weaponbox" };

	for (new i; i < sizeof fieldEnts; i++)
		remove_entity_name(fieldEnts[i]);

	new ent;
	while ((ent = find_ent_by_class(ent, "rpg_rocket")))
		set_pev(ent, pev_dmg, 0);

	ent = 0;
	while ((ent = find_ent_by_class(ent, "grenade")))
		set_pev(ent, pev_dmg, 0);
}

// this will reset hev and health chargers
ResetFuncChargers() {
	new classname[32];
	for (new i; i < global_get(glb_maxEntities); i++) {
		if (pev_valid(i)) {
			pev(i, pev_classname, classname, charsmax(classname));
			if (equal(classname, "func_recharge")) {
				set_pev(i, pev_frame, 0);
				set_pev(i, pev_nextthink, 0);
				set_pdata_int(i, M_IJUICE, 30);
			} else if (equal(classname, "func_healthcharger")) {
				set_pev(i, pev_frame, 0);
				set_pev(i, pev_nextthink, 0);
				set_pdata_int(i, M_IJUICE, 50);
			}
		}
	}
}

// This will respawn all weapons, ammo and items of the map
RespawnItems() {
	new classname[32];
	for (new i; i < global_get(glb_maxEntities); i++) {
		if (pev_valid(i)) {
			pev(i, pev_classname, classname, charsmax(classname));
			if (contain(classname, "weapon_") != -1 || contain(classname, "ammo_") != -1 || contain(classname, "item_") != -1) {
				set_pev(i, pev_nextthink, get_gametime());
			}
		}
	}
}

// TODO: teamplay
// Change player team by teamid without killing him.
/*ChangePlayerTeam(id, teamId) {
	static gameTeamMaster, gamePlayerTeam, spawnFlags;

	if (!gameTeamMaster) {
		gameTeamMaster = create_entity("game_team_master");
		set_pev(gameTeamMaster, pev_targetname, "changeteam");
	}

	if (!gamePlayerTeam) {
		gamePlayerTeam = create_entity("game_player_team");
		DispatchKeyValue(gamePlayerTeam, "target", "changeteam");
	}

	set_pev(gamePlayerTeam, pev_spawnflags, spawnFlags);

	DispatchKeyValue(gameTeamMaster, "teamindex", fmt("%i", teamId - 1));

	ExecuteHamB(Ham_Use, gamePlayerTeam, id, 0, USE_ON, 0.0);
}

// Execute this post client_putinserver
// Change team names from VGUI Menu and VGUI Scoreboard (the last one only works with vanilla clients)
hl_set_teamnames(id, any:...) {
	new teamNames[10][16];
	new numTeams = clamp(numargs() - 1, 0, 10);

	for (new i; i < numTeams; i++)
		format_args(teamNames[i], charsmax(teamNames[]), 1 + i);

	// Send new team names
	message_begin(MSG_ONE, get_user_msgid("TeamNames"), _, id);
	write_byte(numTeams);
	for (new i; i < numTeams; i++)
		write_string(teamNames[i]);
	message_end();
}*/

SetAllGodMode(isgod) {
	hlrm_get_players(gPlayers, gNumPlayers);
	for (new i; i < gNumPlayers; i++)
		set_user_godmode(gPlayers[i], isgod);
}

// TODO: sounds? unused
/*
PlayMp3(id, const file[]) {
	client_cmd(id, "mp3 loop %s", file);
}*/

Speak(id, const speak[]) {
	new spk[128];
	RemoveExtension(speak, spk, charsmax(spk), ".wav"); // remove wav extension to avoid "missing sound file _period.wav"
	client_cmd(id, "speak ^"%s^"", spk);
}

RemoveExtension(const input[], output[], length, const ext[]) {
	copy(output, length, input);

	new idx = strlen(input) - strlen(ext);
	if (idx < 0) return 0;

	return replace(output[idx], length, ext, "");
}
/* AMXX-Studio Notes - DO NOT MODIFY BELOW HERE
*{\\ rtf1\\ ansi\\ deff0{\\ fonttbl{\\ f0\\ fnil Tahoma;}}\n\\ viewkind4\\ uc1\\ pard\\ lang1033\\ f0\\ fs16 \n\\ par }
*/
