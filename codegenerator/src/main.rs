use std::error::Error;

use std::path::PathBuf;

use clap::Parser;

use envio::{
    cli_args::{
        self, DbMigrateSubcommands, Language, LocalCommandTypes, LocalDockerSubcommands,
        ProjectPathsArgs,
    },
    commands,
    hbs_templating::{hbs_dir_generator::HandleBarsDirGenerator, init_templates::InitTemplates},
    persisted_state::PersistedState,
    project_paths::{self, ParsedPaths},
};

use cli_args::{CommandLineArgs, CommandType, Template, ToProjectPathsArgs};
use include_dir::{include_dir, Dir};

static BLANK_TEMPLATE_STATIC_SHARED_DIR: Dir<'_> =
    include_dir!("templates/static/blank_template/shared");
static BLANK_TEMPLATE_STATIC_RESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/blank_template/rescript");
static BLANK_TEMPLATE_STATIC_TYPESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/blank_template/typescript");
static BLANK_TEMPLATE_STATIC_JAVASCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/blank_template/javascript");
static GREETER_TEMPLATE_STATIC_SHARED_DIR: Dir<'_> =
    include_dir!("templates/static/greeter_template/shared");
static GREETER_TEMPLATE_STATIC_RESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/greeter_template/rescript");
static GREETER_TEMPLATE_STATIC_TYPESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/greeter_template/typescript");
static GREETER_TEMPLATE_STATIC_JAVASCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/greeter_template/javascript");
static ERC20_TEMPLATE_STATIC_SHARED_DIR: Dir<'_> =
    include_dir!("templates/static/erc20_template/shared");
static ERC20_TEMPLATE_STATIC_RESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/erc20_template/rescript");
static ERC20_TEMPLATE_STATIC_TYPESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/erc20_template/typescript");
static ERC20_TEMPLATE_STATIC_JAVASCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/erc20_template/javascript");
static INIT_TEMPLATES_SHARED_DIR: Dir<'_> = include_dir!("templates/dynamic/init_templates/shared");

fn main() -> Result<(), Box<dyn Error>> {
    let command_line_args = CommandLineArgs::parse();

    match command_line_args.command {
        CommandType::Init(init_args) => {
            //get_init_args_interactive opens an interactive cli for required args to be selected
            //if they haven't already been
            let args = init_args.get_init_args_interactive()?;
            let project_root_path = PathBuf::from(&args.directory);
            // check that project_root_path exists
            let project_dir = project_paths::path_utils::NewDir::new(project_root_path.clone())?;

            let hbs_template = InitTemplates::new(project_dir.root_dir_name, &args.language);
            let hbs_generator = HandleBarsDirGenerator::new(
                &INIT_TEMPLATES_SHARED_DIR,
                &hbs_template,
                &project_root_path,
            );

            match args.template {
                Template::Blank => {
                    //Copy in the relevant language specific blank template files
                    match &args.language {
                        Language::Rescript => {
                            BLANK_TEMPLATE_STATIC_RESCRIPT_DIR.extract(&project_root_path)?;
                        }
                        Language::Typescript => {
                            BLANK_TEMPLATE_STATIC_TYPESCRIPT_DIR.extract(&project_root_path)?;
                        }
                        Language::Javascript => {
                            BLANK_TEMPLATE_STATIC_JAVASCRIPT_DIR.extract(&project_root_path)?;
                        }
                    }
                    //Copy in the rest of the shared blank template files
                    BLANK_TEMPLATE_STATIC_SHARED_DIR.extract(&project_root_path)?;
                    hbs_generator.generate_hbs_templates()?;
                }
                Template::Greeter => {
                    //Copy in the relevant language specific greeter files
                    match &args.language {
                        Language::Rescript => {
                            GREETER_TEMPLATE_STATIC_RESCRIPT_DIR.extract(&project_root_path)?;
                        }
                        Language::Typescript => {
                            GREETER_TEMPLATE_STATIC_TYPESCRIPT_DIR.extract(&project_root_path)?;
                        }
                        Language::Javascript => {
                            GREETER_TEMPLATE_STATIC_JAVASCRIPT_DIR.extract(&project_root_path)?;
                        }
                    }
                    //Copy in the rest of the shared greeter files
                    GREETER_TEMPLATE_STATIC_SHARED_DIR.extract(&project_root_path)?;
                }
                Template::Erc20 => {
                    //Copy in the relevant js flavor specific greeter files
                    match &args.language {
                        Language::Rescript => {
                            ERC20_TEMPLATE_STATIC_RESCRIPT_DIR.extract(&project_root_path)?;
                        }
                        Language::Typescript => {
                            ERC20_TEMPLATE_STATIC_TYPESCRIPT_DIR.extract(&project_root_path)?;
                        }
                        Language::Javascript => {
                            ERC20_TEMPLATE_STATIC_JAVASCRIPT_DIR.extract(&project_root_path)?;
                        }
                    }
                    //Copy in the rest of the shared greeter files
                    ERC20_TEMPLATE_STATIC_SHARED_DIR.extract(&project_root_path)?;
                }
                Template::SubgraphMigration => {
                    return Ok(())
                }
            }

            println!("Project template ready");
            println!("Running codegen");

            let parsed_paths = ParsedPaths::new(init_args.to_project_paths_args())?;
            let project_paths = &parsed_paths.project_paths;
            commands::codegen::run_codegen(&parsed_paths)?;
            commands::codegen::run_post_codegen_command_sequence(&project_paths)
        }

        CommandType::Codegen(args) => {
            let parsed_paths = ParsedPaths::new(args.to_project_paths_args())?;
            let project_paths = &parsed_paths.project_paths;
            commands::codegen::run_codegen(&parsed_paths)?;
            commands::codegen::run_post_codegen_command_sequence(project_paths)?;

            Ok(())
        }

        CommandType::Start(start_args) => {
            let parsed_paths = ParsedPaths::new(start_args.to_project_paths_args())?;
            let project_paths = &parsed_paths.project_paths;

            //TODO: handle the case where codegen has not been run yet on envio start where
            //persisted state does not exist yet. Currently this will error but it should run
            //the codegen command automatically
            let persisted_state = PersistedState::get_from_generated_file(project_paths)?;
            if start_args.restart || !persisted_state.has_run_db_migrations {
                commands::db_migrate::run_db_setup(project_paths)?;
            }
            commands::start::start_indexer(project_paths)?;
            Ok(())
        }
        CommandType::Local(local_commands) => {
            let parsed_paths = ParsedPaths::new(ProjectPathsArgs::default())?;
            let project_paths = &parsed_paths.project_paths;
            match local_commands {
                LocalCommandTypes::Docker(subcommand) => match subcommand {
                    LocalDockerSubcommands::Up => {
                        commands::docker::docker_compose_up_d(project_paths)?;
                    }
                    LocalDockerSubcommands::Down => {
                        commands::docker::docker_compose_down_v(project_paths)?;
                    }
                },
                LocalCommandTypes::DbMigrate(subcommand) => match subcommand {
                    DbMigrateSubcommands::Up => {
                        commands::db_migrate::run_up_migrations(project_paths)?;
                    }

                    DbMigrateSubcommands::Down => {
                        commands::db_migrate::run_drop_schema(project_paths)?;
                    }

                    DbMigrateSubcommands::Setup => {
                        commands::db_migrate::run_db_setup(project_paths)?;
                    }
                },
            }
            Ok(())
        }
        CommandType::PrintAllHelp {} => {
            clap_markdown::print_help_markdown::<CommandLineArgs>();
            Ok(())
        }
    }
}
