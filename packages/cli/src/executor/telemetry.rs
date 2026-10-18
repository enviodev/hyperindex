use crate::{clap_definitions::TelemetrySubcommand, project_paths::ParsedProjectPaths, telemetry};
use anyhow::Result;

pub fn run(subcommand: TelemetrySubcommand, project_paths: &ParsedProjectPaths) -> Result<()> {
    match subcommand {
        TelemetrySubcommand::Status => print!("{}", telemetry::status_report(project_paths)),
        TelemetrySubcommand::Enable => {
            let path = telemetry::set_enabled(true)?;
            println!(
                "Telemetry is on for this machine (saved in {}). DO_NOT_TRACK and \
                 ENVIO_TELEMETRY_DISABLED still turn it off. Run `envio telemetry status` to see \
                 what is sent.",
                path.display()
            );
        }
        TelemetrySubcommand::Disable => {
            let path = telemetry::set_enabled(false)?;
            println!(
                "Telemetry is off for this machine (saved in {}). Nothing more will be sent.",
                path.display()
            );
        }
    }
    Ok(())
}
