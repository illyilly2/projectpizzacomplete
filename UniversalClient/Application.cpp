#include "Application.h"
#include "v8datamodel/Game.h"
#include "script/LuaVM.h"
#include "FastLog.h"
#include "v8datamodel/GlobalSettings.h"
#include "v8datamodel/DebugSettings.h"
#include "rbx/TaskScheduler.Job.h"
#include "util/Statistics.h"
#include "RobloxServicesTools.h"
#include "v8datamodel/FastLogSettings.h"
#include "v8datamodel/ContentProvider.h"
#include "v8xml/WebParser.h"
#include "network/api.h"
#include "util/SoundService.h"

#ifdef EMSCRIPTEN
#include "emscripten.h"
#include <emscripten/val.h>
#elif !defined(_WIN32)
#include <unistd.h>
#endif

static boost::shared_ptr<RBX::Game> preloadedGame;
static boost::mutex preloadedGameMutex;
static bool preloadShuttingDown = false;
static boost::thread releaseGameThread;

namespace RBX
{
	static std::string readStringValue(shared_ptr<const Reflection::ValueTable> jsonResult, std::string name)
	{
		Reflection::ValueTable::const_iterator itData = jsonResult->find(name);
		if (itData != jsonResult->end())
		{
			return itData->second.get<std::string>();
		}
		else
		{
			throw std::runtime_error(RBX::format("Unexpected string result for %s", name.c_str()));
		}
	}

	static int readIntValue(shared_ptr<const Reflection::ValueTable> jsonResult, std::string name)
	{
		Reflection::ValueTable::const_iterator itData = jsonResult->find(name);
		if (itData != jsonResult->end())
		{
			return itData->second.get<int>();
		}
		else
		{
			throw std::runtime_error(RBX::format("Unexpected int result for %s", name.c_str()));
		}
	}

	static void Sleep(int sleepTime)
	{
#ifdef _WIN32
		Sleep((int)(sleepTime));
#elif defined(EMSCRIPTEN)
		emscripten_sleep((int)(sleepTime));
#else
		usleep((int)(sleepTime * 1e3));
#endif
	}

	bool Application::ParseArguments(SDL_Window *window, int argc, char *argv[])
	{
		po::options_description desc("Options");
		desc.add_options()("help,?", "produce help message")("authenticationUrl,a", po::value<std::string>(), "authentication url from server")("authenticationTicket,t", po::value<std::string>(), "game session ticket from server")("baseUrl,b", po::value<std::string>(), "set a custom baseurl")("joinScriptUrl,j", po::value<std::string>(), "url of launch script from server");

		po::store(po::parse_command_line(argc, argv, desc), vm);
		po::notify(vm);

		if (vm.count("help") || vm.size() == 0)
		{
			std::basic_stringstream<char> options;
			desc.print(options);
			SDL_ShowSimpleMessageBox(0, "Roblox", options.str().c_str(), window);
			return false;
		}

		if (vm.count("baseUrl"))
		{
			SetBaseURL(vm["baseUrl"].as<std::string>());
		}
		else
		{
			SetBaseURL("");
		}

		return true;
	}

	Application::RequestPlaceInfoResult Application::requestPlaceInfo(const std::string url, std::string &authenticationUrl, std::string &ticket, std::string &scriptUrl) const
	{
		try
		{
			std::string response;
			std::istringstream input("");
			RBX::Http(url).post(input, RBX::Http::kContentTypeDefaultUnspecified, false, response);

			std::stringstream jsonStream;
			jsonStream << response;
			shared_ptr<const Reflection::ValueTable> jsonResult(rbx::make_shared<const Reflection::ValueTable>());
			bool parseResult = WebParser::parseJSONTable(jsonStream.str(), jsonResult);
			if (parseResult)
			{
				int status = readIntValue(jsonResult, "status");
				if (status == 2)
				{
					authenticationUrl = readStringValue(jsonResult, "authenticationUrl");
					ticket = readStringValue(jsonResult, "authenticationTicket");
					scriptUrl = readStringValue(jsonResult, "joinScriptUrl");
					return SUCCESS;
				}
				else if (status == 6)
					return GAME_FULL;
				else if (status == 10)
					return USER_LEFT;
				else
				{
					if (status == 0 || status == 1)
						return RETRY;
				}
			}
		}
		catch (RBX::base_exception &e)
		{
			StandardOut::singleton()->printf(MESSAGE_ERROR, "Exception when requesting place info: %s. ", e.what());
		}

		return FAILED;
	}

	void Application::onMessageOut(const StandardOutMessage &message)
	{
		std::string level;

		switch (message.type)
		{
		case MESSAGE_INFO:
			level = "INFO";
			break;
		case MESSAGE_WARNING:
			level = "WARNING";
			break;
		case MESSAGE_ERROR:
			level = "ERROR";
			break;
		default:
			level.clear();
			break;
		}

		std::cout << level << ": " << message.message << std::endl;
	}

	static void do_preloadGame()
	{
		releaseGameThread.join();

		boost::mutex::scoped_lock lock(preloadedGameMutex);
		if (!preloadedGame)
		{
			RBX::Time start = RBX::Time::now<RBX::Time::Fast>();
			preloadedGame.reset(new RBX::SecurePlayerGame(NULL, ::GetBaseURL().c_str()));
			RBX::Time stop = RBX::Time::now<RBX::Time::Fast>();
			double secs = (stop - start).seconds();
			RBX::StandardOut::singleton()->printf(RBX::MESSAGE_OUTPUT, "Preloaded Game %gsec", secs);
		}
		else
			RBX::StandardOut::singleton()->printf(RBX::MESSAGE_OUTPUT, "Already preloaded Game");
	}

	void Application::preloadGame()
	{
		RBX::StandardOut::singleton()->printf(RBX::MESSAGE_OUTPUT, "Requesting preload Game");
		boost::thread(boost::bind(&do_preloadGame));
	}

	boost::shared_ptr<RBX::Game> Application::getPreloadedGame()
	{
		boost::mutex::scoped_lock lock(preloadedGameMutex);
		if (!preloadedGame)
		{
			RBX::Time start = RBX::Time::now<RBX::Time::Fast>();
			preloadedGame.reset(new RBX::SecurePlayerGame(NULL, ::GetBaseURL().c_str()));
			RBX::Time stop = RBX::Time::now<RBX::Time::Fast>();
			double secs = (stop - start).seconds();
			RBX::StandardOut::singleton()->printf(RBX::MESSAGE_OUTPUT, "Loaded Game %gsec", secs);
		}
		return preloadedGame;
	}

	boost::shared_ptr<View> Application::Initialize(SDL_Window *window)
	{
		mainWindow = window;
		StandardOut::singleton()->messageOut.connect(&Application::onMessageOut);

		Game::globalInit(false);
		if (RBX::DataModel::hash.length() == 0)
		{
			RBX::DataModel::hash = "";
		}

#ifdef EMSCRIPTEN
		RBX::ContentProvider::setAssetFolder("/content");
#else
		RBX::ContentProvider::setAssetFolder("content");
#endif

		std::string authenticationUrl;
		std::string authenticationTicket;
		std::string scriptUrl;
		bool scriptIsPlaceLauncher = false;

#ifndef EMSCRIPTEN
		std::string clientSettingsString;
		FetchClientSettingsData(CLIENT_APP_SETTINGS_STRING, CLIENT_SETTINGS_API_KEY, &clientSettingsString);
		LoadClientSettingsFromString(CLIENT_APP_SETTINGS_STRING, clientSettingsString, &RBX::ClientAppSettings::singleton());
#else
		emscripten::val Module = emscripten::val::global("Module");
		if (Module.hasOwnProperty("fastFlags"))
		{
			std::string fastFlags = Module["fastFlags"].as<std::string>();
			LoadClientSettingsFromString(CLIENT_APP_SETTINGS_STRING, fastFlags, &RBX::ClientAppSettings::singleton());
		}
#endif

#ifdef RBX_SECURE_DOUBLE
		LuaSecureDouble::initDouble();
#endif

		preloadGame();

		FLog::ResetSynchronizedVariablesState();
		RBX::GlobalAdvancedSettings::singleton();

		RBX::Security::Impersonator impersonate(RBX::Security::RobloxGameScript_);
		RBX::GlobalBasicSettings::singleton();

		TaskScheduler::singleton().setThreadCount(TaskSchedulerSettings::singleton().getThreadPoolConfig());

		view.reset(new View(window));
		view->Start(Application::getPreloadedGame());
		SDL_ShowWindow(window);

		if (vm.count("authenticationUrl") && vm.count("authenticationTicket") && vm.count("joinScriptUrl"))
		{
			authenticationUrl = vm["authenticationUrl"].as<std::string>();
			authenticationTicket = vm["authenticationTicket"].as<std::string>();
			scriptUrl = vm["joinScriptUrl"].as<std::string>();

			std::string lowerScriptUrl = scriptUrl;
			std::transform(lowerScriptUrl.begin(), lowerScriptUrl.end(), lowerScriptUrl.begin(), tolower);
			if (lowerScriptUrl.find("placelauncher") != std::string::npos)
			{
				scriptIsPlaceLauncher = true;
			}

			RBX::StandardOut::singleton()->printf(RBX::MESSAGE_INFO, "Script URL: %s; Auth URL: %s;", scriptUrl.c_str(), authenticationUrl.c_str());
			if (!scriptIsPlaceLauncher)
			{
				shared_ptr<DataModel> dataModel = view->getDataModel();
				dataModel->submitTask(boost::bind(&View::ExecuteScript, view.get(), scriptUrl, 0), DataModelJob::Write);
			}
			else
			{
				view->SetUiMessage("Requesting Server...");
				launchPlaceThread.reset(new boost::thread(RBX::thread_wrapper(boost::bind(&Application::LaunchPlaceThreadImpl, this, scriptUrl), "Launch Place Thread")));
			}
		}

		return view;
	}

	void Application::Shutdown()
	{
		view->Stop();
		Game::globalExit();
	}

	void Application::LaunchPlaceThreadImpl(const std::string &placeLauncherUrl)
	{
		std::string authenticationUrl;
		std::string authenticationTicket;
		std::string joinScriptUrl;
		Time startTime = Time::nowFast();

		if (boost::shared_ptr<RBX::DataModel> dataModel = view->getDataModel())
		{
			std::string requestType;
			std::string url = placeLauncherUrl;
			std::string requestArg = "request=";
			size_t requestPos = url.find(requestArg);
			if (requestPos != std::string::npos)
			{
				size_t requestEndPos = url.find("&", requestPos);
				if (requestEndPos == std::string::npos)
					requestEndPos = url.length();

				size_t requestTypeStartPos = requestPos + requestArg.size();
				requestType = url.substr(requestTypeStartPos, requestEndPos - requestTypeStartPos);
			}

			int retries = 5;
			RequestPlaceInfoResult res;
			while (retries >= 0)
			{
				res = Application::requestPlaceInfo(placeLauncherUrl, authenticationUrl, authenticationTicket, joinScriptUrl);

				if (dataModel->isClosed())
					break;

				switch (res)
				{
				case SUCCESS:
				{
					dataModel->submitTask(boost::bind(&View::ExecuteScript, view.get(), joinScriptUrl, 1), DataModelJob::Write);
					return;
				}
				break;
				case FAILED:
					retries--;
				case RETRY:
					Sleep(2000);
					break;
				case GAME_FULL:
					view->SetUiMessage("The game you requested is currently full. Waiting for an opening...");
					Sleep(2000);
					break;
				case USER_LEFT:
					view->SetUiMessage("The user has left the game.");
					retries = -1;
					break;
				default:
					break;
				}
			}

			if (res == FAILED)
			{
				view->SetUiMessage("Failed to request game, please try again.");
			}
		}
	}
}