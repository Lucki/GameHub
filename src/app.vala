/*
This file is part of GameHub.
Copyright (C) 2018-2019 Anatoliy Kashkin

GameHub is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

GameHub is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GameHub.  If not, see <https://www.gnu.org/licenses/>.
*/

using Gtk;
using Gdk;
using Granite;

using GameHub.Data;
using GameHub.Data.DB;
using GameHub.Data.Sources.Steam;
using GameHub.Data.Sources.GOG;
using GameHub.Data.Sources.Humble;
using GameHub.Data.Sources.User;
using GameHub.Utils;

namespace GameHub
{
	public class Application: Gtk.Application
	{
		public static Application instance;

		public static bool log_auth = false;
		public static bool log_downloader = false;
		public static bool log_workers = false;
		public static bool log_verbose = false;

		private static bool opt_help = false;
		private static bool opt_debug_log = false;
		private static bool opt_show_version = false;

		private static string? opt_run = null;
		private static string? opt_game_details = null;
		private static string? opt_game_properties = null;

		private static bool opt_show_compat = false;
		private static bool opt_show = false;
		private static bool opt_settings = false;
		private static bool opt_gdb = false;
		private static bool opt_gdb_bt_full = false;

		public static int worker_threads = -1;

		private GameHub.UI.Windows.MainWindow? main_window;

		public const string ACTION_PREFIX                          = "app.";
		public const string ACTION_SETTINGS                        = "settings";
		public const string ACTION_CORRUPTED_INSTALLER_PICK_ACTION = "corrupted-installer.pick-action";
		public const string ACTION_CORRUPTED_INSTALLER_SHOW        = "corrupted-installer.show";
		public const string ACTION_CORRUPTED_INSTALLER_BACKUP      = "corrupted-installer.backup";
		public const string ACTION_CORRUPTED_INSTALLER_REMOVE      = "corrupted-installer.remove";
		public const string ACTION_GAME_RUN                        = "game.run";
		public const string ACTION_GAME_DETAILS                    = "game.details";
		public const string ACTION_GAME_PROPERTIES                 = "game.properties";

		private const GLib.ActionEntry[] action_entries = {
			{ ACTION_SETTINGS,                        action_settings },
			{ ACTION_CORRUPTED_INSTALLER_PICK_ACTION, action_corrupted_installer, "(ss)" },
			{ ACTION_CORRUPTED_INSTALLER_SHOW,        action_corrupted_installer, "(ss)" },
			{ ACTION_CORRUPTED_INSTALLER_BACKUP,      action_corrupted_installer, "(ss)" },
			{ ACTION_CORRUPTED_INSTALLER_REMOVE,      action_corrupted_installer, "(ss)" },
			{ ACTION_GAME_RUN,                        action_game, "s" },
			{ ACTION_GAME_DETAILS,                    action_game, "s" },
			{ ACTION_GAME_PROPERTIES,                 action_game, "s" }
		};

		private const OptionEntry[] local_options = {
			{ "help", 'h', 0, OptionArg.NONE, out opt_help, N_("Show help"), null },
			{ "version", 'v', 0, OptionArg.NONE, out opt_show_version, N_("Show application version and exit"), null },
			{ "gdb", 0, 0, OptionArg.NONE, out opt_gdb, N_("Restart with GDB debugger attached"), null },
			{ "gdb-bt-full", 0, 0, OptionArg.NONE, out opt_gdb_bt_full, N_("Show full GDB backtrace"), null },
			{ null }
		};
		private const OptionEntry[] options = {
			{ "show", 's', 0, OptionArg.NONE, out opt_show, N_("Show main window"), null },
			{ "settings", 0, 0, OptionArg.NONE, out opt_settings, N_("Show application settings dialog"), null },
			{ "worker-threads", 'j', 0, OptionArg.INT, out worker_threads, N_("Maximum number of background worker threads"), "THREADS" },
			{ null }
		};
		private const OptionEntry[] options_game = {
			{ "run", 'r', 0, OptionArg.STRING, out opt_run, N_("Run game"), "GAME" },
			{ "show-compat", 'c', 0, OptionArg.NONE, out opt_show_compat, N_("Show compatibility options dialog"), null },
			{ "details", 0, 0, OptionArg.STRING, out opt_game_details, N_("Open game details"), "GAME" },
			{ "properties", 0, 0, OptionArg.STRING, out opt_game_properties, N_("Open game properties"), "GAME" },
			{ null }
		};
		private const OptionEntry[] options_log = {
			{ "debug", 'd', 0, OptionArg.NONE, out opt_debug_log, N_("Enable debug logging"), null },
			{ "log-auth", 0, 0, OptionArg.NONE, out log_auth, N_("Log authentication process and sensitive information like authentication tokens"), null },
			{ "log-downloader", 0, 0, OptionArg.NONE, out log_downloader, N_("Log download manager"), null },
			{ "log-workers", 0, 0, OptionArg.NONE, out log_workers, N_("Log background workers start/stop"), null },
			{ "verbose", 0, 0, OptionArg.NONE, out log_verbose, N_("Verbose logging"), null },
			{ null }
		};

		construct
		{
			application_id = ProjectConfig.PROJECT_NAME;
			flags = ApplicationFlags.HANDLES_COMMAND_LINE;
			instance = this;
			add_action_entries(action_entries, this);
		}

		private void init()
		{
			if(Platforms != null && GameSources != null && CompatTools != null) return;

			FSUtils.make_dirs();

			Database.create();

			Platforms = { Platform.LINUX, Platform.WINDOWS, Platform.MACOS };
			CurrentPlatform = Platform.LINUX;

			GameSources = { new Steam(), new GOG(), new Humble(), new Trove(), new User() };

			CompatTool[] tools = { new Compat.CustomScript(), new Compat.CustomEmulator(), new Compat.Innoextract(), new Compat.WineWrap(), new Compat.DOSBox(), new Compat.ScummVM(), new Compat.RetroArch() };
			foreach(var appid in Compat.Proton.APPIDS)
			{
				tools += new Compat.Proton(appid);
			}

			string[] wine_binaries = { "wine"/*, "wine64", "wine32"*/ };
			string[] wine_arches = { "win64", "win32" };

			foreach(var wine_binary in wine_binaries)
			{
				foreach(var wine_arch in wine_arches)
				{
					if(wine_binary == "wine32" && wine_arch == "win64") continue;
					tools += new Compat.Wine(wine_binary, wine_arch);
				}
			}

			CompatTools = tools;

			weak IconTheme default_theme = IconTheme.get_default();
			default_theme.add_resource_path("/com/github/tkashkin/gamehub/icons");

			var screen = Screen.get_default();

			var app_provider = new CssProvider();
			app_provider.load_from_resource("/com/github/tkashkin/gamehub/css/app.css");

			var elementary_provider = new CssProvider();
			elementary_provider.load_from_resource("/com/github/tkashkin/gamehub/css/themes/elementary.css");

			StyleContext.add_provider_for_screen(screen, app_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

			var settings = Gtk.Settings.get_for_screen(screen);
			settings.notify["gtk-theme-name"].connect(() => {
				if(settings.gtk_theme_name == "elementary")
				{
					StyleContext.add_provider_for_screen(screen, elementary_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
				}
				else
				{
					StyleContext.remove_provider_for_screen(screen, elementary_provider);
				}
			});
			settings.notify_property("gtk-theme-name");
		}

		protected override void activate()
		{
			if(main_window == null)
			{
				print_version(false);
				init();

				#if MANETTE
				GameHub.Utils.Gamepad.init();
				#endif

				main_window = new GameHub.UI.Windows.MainWindow(this);
				main_window.show_all();
			}
		}

		public static int main(string[] args)
		{
			#if MANETTE
			X.init_threads();
			#endif

			var app = new Application();

			Utils.Logger.initialize("GameHub");

			var lang = Environment.get_variable("LC_ALL") ?? "";
			Intl.setlocale(LocaleCategory.ALL, lang);
			Intl.bindtextdomain(ProjectConfig.GETTEXT_PACKAGE, ProjectConfig.GETTEXT_DIR);
			Intl.textdomain(ProjectConfig.GETTEXT_PACKAGE);

			return app.run(args);
		}

		private OptionGroup get_game_option_group()
		{
			var group = new OptionGroup("game", _("Game Options:"), _("Show game options help"));
			group.add_entries(options_game);
			group.set_translation_domain(ProjectConfig.GETTEXT_PACKAGE);
			return group;
		}

		private OptionGroup get_log_option_group()
		{
			var group = new OptionGroup("log", _("Logging Options:"), _("Show logging options help"));
			group.add_entries(options_log);
			group.set_translation_domain(ProjectConfig.GETTEXT_PACKAGE);
			return group;
		}

		public override bool local_command_line(ref weak string[] arguments, out int exit_status)
		{
			OptionContext local_option_context = new OptionContext();
			local_option_context.set_ignore_unknown_options(true);
			local_option_context.set_help_enabled(false);
			local_option_context.add_main_entries(local_options, ProjectConfig.GETTEXT_PACKAGE);
			local_option_context.set_translation_domain(ProjectConfig.GETTEXT_PACKAGE);

			try
			{
				unowned string[] args = arguments;
				local_option_context.parse(ref args);
			}
			catch(Error e)
			{
				warning(e.message);
			}

			if(opt_show_version)
			{
				print_version(true);
				exit_status = 0;
				return true;
			}

			if(opt_help)
			{
				OptionContext help_option_context = new OptionContext();
				help_option_context.set_help_enabled(false);
				help_option_context.add_main_entries(local_options, ProjectConfig.GETTEXT_PACKAGE);
				help_option_context.add_main_entries(options, ProjectConfig.GETTEXT_PACKAGE);
				help_option_context.add_group(get_game_option_group());
				help_option_context.add_group(get_log_option_group());
				help_option_context.add_group(Gtk.get_option_group(true));
				help_option_context.set_translation_domain(ProjectConfig.GETTEXT_PACKAGE);
				print(help_option_context.get_help(false, null));
				exit_status = 0;
				return true;
			}

			Granite.Services.Logger.DisplayLevel = opt_debug_log ? Granite.Services.LogLevel.DEBUG : Granite.Services.LogLevel.INFO;

			if(opt_gdb || opt_gdb_bt_full)
			{
				string[] current_args = arguments;
				string[] cmd_args = {};
				for(int i = 1; i < current_args.length; i++)
				{
					var arg = current_args[i];
					if(arg != "--gdb")
					{
						cmd_args += arg;
					}
				}
				if(!("--debug" in cmd_args) && !("-d" in cmd_args))
				{
					cmd_args += "--debug";
				}
				string cmd_args_string = string.joinv(" ", cmd_args);

				string[] exec_cmd = {
					"gdb", "-q", "--batch",
					"-ex", @"set args $cmd_args_string",
					"-ex", "set pagination off",
					"-ex", "handle SIGHUP nostop pass",
					"-ex", "handle SIGQUIT nostop pass",
					"-ex", "handle SIGPIPE nostop pass",
					"-ex", "handle SIGALRM nostop pass",
					"-ex", "handle SIGTERM nostop pass",
					"-ex", "handle SIGUSR1 nostop pass",
					"-ex", "handle SIGUSR2 nostop pass",
					"-ex", "handle SIGCHLD nostop pass",
					"-ex", "set print thread-events off",
					"-ex", "run",
					"-ex", "thread apply all bt" + (opt_gdb_bt_full ? " full" : ""),
					"--tty=/dev/stdout",
					current_args[0]
				};

				info("Restarting with GDB");
				Utils.run(exec_cmd, Environment.get_current_dir());
				exit_status = 0;
				return true;
			}

			return base.local_command_line(ref arguments, out exit_status);
		}

		public override int command_line(ApplicationCommandLine cmd)
		{
			string[] oargs = cmd.get_arguments();
			unowned string[] args = oargs;

			var option_context = new OptionContext();
			option_context.add_main_entries(options, ProjectConfig.GETTEXT_PACKAGE);
			option_context.add_group(get_game_option_group());
			option_context.add_group(get_log_option_group());
			option_context.add_group(Gtk.get_option_group(true));
			option_context.set_translation_domain(ProjectConfig.GETTEXT_PACKAGE);

			try
			{
				option_context.parse(ref args);
			}
			catch(Error e)
			{
				warning(e.message);
			}

			Granite.Services.Logger.DisplayLevel = opt_debug_log ? Granite.Services.LogLevel.DEBUG : Granite.Services.LogLevel.INFO;

			init();

			if(opt_show || (opt_run == null && opt_game_details == null && opt_game_properties == null))
			{
				activate();
				main_window.present();
			}

			if(opt_settings)
			{
				activate_action(ACTION_SETTINGS, null);
			}

			if(opt_run != null)
			{
				activate_action(ACTION_GAME_RUN, new Variant.string(opt_run));
			}

			if(opt_game_details != null)
			{
				activate_action(ACTION_GAME_DETAILS, new Variant.string(opt_game_details));
			}

			if(opt_game_properties != null)
			{
				activate_action(ACTION_GAME_PROPERTIES, new Variant.string(opt_game_properties));
			}

			opt_run = null;
			opt_game_details = null;
			opt_game_properties = null;

			opt_show_compat = false;
			opt_show = false;
			opt_settings = false;

			return 0;
		}

		[PrintfFormat]
		private void println(bool plain, string format, ...)
		{
			var line = format.vprintf(va_list());
			if(plain)
			{
				print(line + "\n");
			}
			else
			{
				info(line);
			}
		}

		private void print_version(bool plain)
		{
			println(plain, "Version: %s", ProjectConfig.VERSION);
			println(plain, "Branch:  %s", ProjectConfig.GIT_BRANCH);
			println(plain, "Commit:  %s (%s)", ProjectConfig.GIT_COMMIT_SHORT, ProjectConfig.GIT_COMMIT);
			println(plain, "Distro:  %s", Utils.get_distro());
			println(plain, "DE:      %s", Utils.get_desktop_environment() ?? "unknown");
		}

		private static async void run_game(Game game, bool show_compat)
		{
			if(game.status.state == Game.State.INSTALLED)
			{
				if(game.use_compat)
				{
					yield game.run_with_compat(show_compat);
				}
				else
				{
					yield game.run();
				}
			}
			else if(game.status.state == Game.State.UNINSTALLED)
			{
				yield game.install();
			}
		}

		private static void action_settings(SimpleAction action, Variant? args)
		{
			new UI.Dialogs.SettingsDialog.SettingsDialog();
		}

		private static void action_corrupted_installer(SimpleAction action, Variant? args)
		{
			if(args == null) return;

			var args_iter = args.iterator();
			string? game_id = null;
			string? path = null;
			args_iter.next("s", &game_id);
			args_iter.next("s", &path);

			if(game_id == null || path == null) return;

			var file = FSUtils.file(path);
			if(file == null || !file.query_exists()) return;
			try
			{
				switch(action.name)
				{
					case ACTION_CORRUPTED_INSTALLER_PICK_ACTION:
						game_id = game_id.strip();
						if(game_id.length > 0 && ":" in game_id)
						{
							var id_parts = game_id.split(":");
							var game = GameHub.Data.DB.Tables.Games.get(id_parts[0], id_parts[1]);
							if(game != null)
							{
								var loop = new MainLoop();
								var dlg = new UI.Dialogs.CorruptedInstallerDialog(game, file);
								dlg.destroy.connect(() => {
									loop.quit();
								});
								loop.run();
							}
						}
						break;

					case ACTION_CORRUPTED_INSTALLER_SHOW:
						Utils.open_uri(file.get_parent().get_uri());
						break;

					case ACTION_CORRUPTED_INSTALLER_BACKUP:
						file.move(FSUtils.file(path + ".backup"), FileCopyFlags.BACKUP);
						break;

					case ACTION_CORRUPTED_INSTALLER_REMOVE:
						file.delete();
						break;
				}
			}
			catch(Error e)
			{
				warning("[app.installer_action] %s", e.message);
			}
		}

		private static void action_game(SimpleAction action, Variant? args)
		{
			if(args == null) return;
			string? game_id = args.get_string();
			if(game_id == null) return;

			game_id = game_id.strip();
			if(game_id.length > 0 && ":" in game_id)
			{
				var id_parts = game_id.split(":");
				var game = GameHub.Data.DB.Tables.Games.get(id_parts[0], id_parts[1]);
				if(game != null)
				{
					var loop = new MainLoop();
					game.update_game_info.begin((obj, res) => {
						game.update_game_info.end(res);
						switch(action.name)
						{
							case ACTION_GAME_RUN:
								info("Starting `%s`", game.name);
								run_game.begin(game, opt_show_compat, (obj, res) => {
									run_game.end(res);
									info("`%s` finished", game.name);
									loop.quit();
								});
								break;

							case ACTION_GAME_DETAILS:
								var dlg = new UI.Dialogs.GameDetailsDialog(game);
								dlg.destroy.connect(() => {
									loop.quit();
								});
								break;

							case ACTION_GAME_PROPERTIES:
								var dlg = new UI.Dialogs.GamePropertiesDialog(game);
								dlg.destroy.connect(() => {
									loop.quit();
								});
								break;
						}
					});
					loop.run();
				}
				else
				{
					error("Game with id `%s` from source `%s` is not found", id_parts[1], id_parts[0]);
				}
			}
			else
			{
				error("`%s` is not a fully-qualified game id", opt_run);
			}
		}
	}
}
