ScriptConfig		<- {};
DiscordSocket 		<- false;

/*
	Utility function(s)
*/
function lineSplit(string){
	local find = true;
	local strings = [];
	
	do {
		find = string.find("\r\n");			
		strings.push(string.slice(0, find));
		string = string.slice(find, string.len());				
	} while (find)	
	
	return strings;
}

// from http://forum.liberty-unleashed.co.uk/index.php/topic,639.0.html
function GetPlayersTable()
{
	local players = {};
	
	for (local player, id = 0, count = GetMaxPlayers(); id < count; id++)
		if ((player = FindPlayer(id))) players.rawset(player.Name,player);
	
	return players;
}
/*
	/Utility function(s)
*/


function onScriptLoad(){
	::dofile("Scripts/lu-util/json_functions.nut");
	::dofile("Scripts/lu-util/events_s.nut");
	
	if(!::LoadModule("lu_hashing2")){
		::print("[lu-discord] Failed to load hashing2 module. Not installed?");
		return null;
	}
	
	createSocketFromConfig();	
	addEvent("onDiscordMessage");
	addEvent("onDiscordCommand");	
	
}

function onScriptUnload(){
	::print("[lu-discord] Discord echo script unloaded");
	DiscordSocket.Stop();
	DiscordSocket.Delete();
}

function createSocketFromConfig(){	
	local xmlConfigFile = ::XmlDocument();
	try {
		xmlConfigFile.LoadFile("Scripts/lu-discord/config.xml");

		local xmlSettings 	= xmlConfigFile.FirstChild();
		local xmlSetting 	= xmlSettings.FirstChild();
		do {
			ScriptConfig[xmlSetting.GetAttribute("name")] <- xmlSetting.Text;
			xmlSetting = xmlSetting.NextSibling();
		} while(xmlSetting)
	}catch(error){
		::print("[lu-discord] Error loading settings.xml: " + error);
		return null;
	}
	
	DiscordSocket = ::NewSocket(handleSocketData);
	DiscordSocket.SetLostConnFunc(socketDisconnected);
	DiscordSocket.SetNewConnFunc(socketConnected);	
	ScriptConfig["port"] = ScriptConfig["port"].tointeger();
	socketConnect(ScriptConfig["hostname"], ScriptConfig["port"]);
}

function socketConnect(host, port){
	print("[lu-discord] Attempting to connect to " + ScriptConfig["hostname"] + ":" + ScriptConfig["port"]);	
	DiscordSocket.Connect(host, port);
}

function socketDisconnected(socket){
	print("[lu-discord] Disconnected from " + ScriptConfig["hostname"] + ":" + ScriptConfig["port"]);	
	NewTimer("socketConnect", 15000, 1, ScriptConfig["hostname"], ScriptConfig["port"]);
}

function socketConnected(socket){
	print("[lu-discord] Connected to server " + ScriptConfig["hostname"] + ":" + ScriptConfig["port"]);
	sendAuthPacket(socket);
}

function sendSocketData(socket, data){ 
	socket.Send(base64_encode(data) + "\r\n"); 
};

function handleSocketData(socket, data){
	local lines = lineSplit(data);
	foreach(index, line in lines){
		line = base64_decode(line);
		local json = json_decode(line);
		if(typeof(json) == "table"){
			if(typeof(json.type) == "string"){
				handleDiscordPacket(socket, json.type, (json.rawin("payload") && typeof(json.payload) == "table" ? json.payload : {}));
			}
		}
	}
}

function sendAuthPacket(socket){
	local number = GetTickCount()+time();
	local salt = MD5(number.tostring()).tolower();
	local data = json_encode({
		type = "auth", 
		payload = {
			salt = salt, 
			passphrase = SHA256(salt + SHA512(ScriptConfig["passphrase"]).tolower()).tolower()
		}
	});
	sendSocketData(socket, data);
}

function handlePingPacket(socket){
	sendSocketData(socket, json_encode({ type = "pong" }));
}

function handleAuthPacket(socket, payload){
	if(payload.rawin("authenticated") && payload.authenticated){
		print("[lu-discord] Succesfully authenticated");
		sendSocketData(socket, json_encode({
			type = "select-channel",
			payload = {
				channel = ScriptConfig["channel"]
			}
		}));
	}else{
		local error = (payload.rawin("error") ? payload.error.tostring() : "Unknown error");
		print("[lu-discord] Failed to authenticate: " + error);
		socket.Stop();
	}
}

function handleSelectChannelPacket(socket, payload){
	if(payload.rawin("success") && payload.success){
		if(payload.rawin("wait") && payload.wait){
			print("[lu-discord] Bot isn't ready");
		}else{
			print("[lu-discord] Channel has been bound");
			sendSocketData(socket, json_encode({
				type = "chat.message.text",
				payload = {
					author 	= "Console",
					text	= "Hello :wave:"
				}
			}));
		}
	}else{
		local error = (payload.rawin("error") ? payload.rawin("error").tostring() : "Unknown error");
		print("[lu-discord] Failed to bind channel: " + error);
	}
}

function handleDisconnectPacket(socket){
	print("[lu-discord] Server has closed the connection");
	socket.Stop();
}

function handleDiscordPacket(socket, packet, payload){
	switch(packet){
		case "ping":
			return handlePingPacket(socket);
			break;
		case "auth":
			return handleAuthPacket(socket, payload);
			break;
		case "select-channel":
			return handleSelectChannelPacket(socket, payload);
			break;
		case "disconnect":
			return handleDisconnectPacket(socket);
			break;
		default:
			return handleDiscordDefaultPacket(socket, packet, payload);
	}
}

/*
	Event and chat functions
*/

function handleDiscordDefaultPacket(socket, packet, payload){
	if(packet == "text.message"){
		print(format("[lu-discord] %s: %s", payload.author.name, payload.message.text));
		Message(format("%s on Discord:[#FFFFFF] %s", payload.author.name, payload.message.text), 114, 237, 218);
		
		triggerEvent("onDiscordMessage", payload.author.name, payload.message.text);
		
		local data = json_encode({
			type = "chat.confirm.message", 
			payload = {
				author = payload.author.name,
				message = payload.message
			}
		});
		sendSocketData(socket, data);			
	}else if(packet == "text.command"){
		local varparams = [getroottable(), "onDiscordCommand", payload.author.name, json_encode(payload.author.roles), payload.message.text, payload.message.command, json_encode(payload.message.params)];

		local isAdmin = payload.author.roles.find(ScriptConfig["adminrole"]) != null;
		switch(payload.message.command){
			case "players":
				local players = GetPlayersTable();
				local playerlist = "";
				foreach(name, player in players){
					playerlist += name + " ";
				}
				local data = json_encode({
					type = "chat.message.text", 
					payload = {
						author = "Console",
						text = "Players currently in game: " + playerlist
					}
				});
				sendSocketData(socket, data);					
				break; 
				
			case "kick":
				if(isAdmin && payload.message.params.len()){
					local plr = ::FindPlayer(payload.message.params[0]);
					if(plr){
						local reason = getReason(payload.message.params);
						::MessagePlayer(format("You were kicked from the game by %s: [#FFFFFF]%s", payload.author.name, reason), plr);
						::KickPlayer(plr);
					}
				}
				break;
				
			//Banning command handlers
			case "banname":
				bantype <- BANTYPE_NAME;
			case "banip":
				//we didnt use break; above this case so this code will run even when the command is not banip
				if(payload.message.command == "banip"){ bantype <- BANTYPE_IP; }
			case "banluid":
				if(payload.message.command == "banluid"){ bantype <- BANTYPE_LUID; }
				
				if(isAdmin && payload.message.params.len()){
					local plr = ::FindPlayer(payload.message.params[0]);
					if(plr){
						local reason = getReason(payload.message.params);
						::MessagePlayer(format("You were banned from the game by %s: [#FFFFFF]%s", payload.author.name, reason), plr);
						local pLUID = plr.LUID;
						local pIP = plr.IP;
						local pName = plr.Name;
						::BanPlayer(plr, bantype);
						
						local data = json_encode({
							type = "chat.message.text", 
							payload = {
								author = "Console",
								text = format("Banned player %s, IP: %s, LUID: %s", pName, pIP, pLUID)
							}
						});
						sendSocketData(socket, data);	
					}					
				}
				bantype <- null;
				break;

			//unbanning command handlers
			case "unbanname":
				if(isAdmin && payload.message.params.len()){
					if(::UnbanName(payload.message.params[0])){
						local data = json_encode({
							type = "chat.message.text", 
							payload = {
								author = "Console",
								text = "Unbanned name " + payload.message.params[0]
							}
						});
						sendSocketData(socket, data);	
					}
				}				
				break;
				
			case "unbanluid":
				if(isAdmin && payload.message.params.len()){
					if(::UnbanLUID(payload.message.params[0])){
						local data = json_encode({
							type = "chat.message.text", 
							payload = {
								author = "Console",
								text = "Unbanned LUID " + payload.message.params[0]
							}
						});
						sendSocketData(socket, data);	
					}
				}				
				break;	
				
			case "unbanip":
				if(isAdmin && payload.message.params.len()){
					if(::UnbanIP(payload.message.params[0])){
						local data = json_encode({
							type = "chat.message.text", 
							payload = {
								author = "Console",
								text = "Unbanned IP " + payload.message.params[0]
							}
						});
						sendSocketData(socket, data);	
					}
				}				
				break;		
				
		}
		triggerEvent.acall(varparams);
	}
}

function getReason(params){
	//remove the player parameter
	params.remove(0); 
	local reason = "";
	foreach(param in params){
		reason += strip(param) + " ";		
	}
	return reason;
}

function onPlayerConnect(plr){
	local data = json_encode({
		type = "player.join", 
		payload = {
			player = plr.Name
		}
	});
	sendSocketData(DiscordSocket, data);
	return 1;
}

function onPlayerPart(plr, reason){
	local quitType = null;
	switch(reason){
		case PARTREASON_DISCONNECTED:
			quitType = "Disconnected";
			break;
		case PARTREASON_CRASHED:
			quitType = "Crashed";
			break;
		case PARTREASON_TIMEOUT:
			quitType = "Timeout";
			break;
		case PARTREASON_KICKED:
			quitType = "Kicked";
			break;
		case PARTREASON_BANNED:
			quitType = "Banned";
			break;			
	}
	local data = json_encode({
		type = "player.quit", 
		payload = {
			player = plr.Name,
			type = quitType,
			reason = false
		}
	});
	sendSocketData(DiscordSocket, data);
	return 1;
}

function onPlayerChat(plr, message){
	local data = json_encode({
		type = "chat.message.text", 
		payload = {
			author = plr.Name,
			text = message
		}
	});
	sendSocketData(DiscordSocket, data);	
	return 1;
}