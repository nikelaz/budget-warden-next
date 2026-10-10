use std::io::{self, Write};
use std::process::ExitCode;

use clap::Parser;

use bw_cli::{Cli, dispatch, error::usage_error};

fn emit_response(line: &str, exit_code: u8) -> ExitCode {
    match writeln!(io::stdout().lock(), "{line}") {
        Ok(()) => ExitCode::from(exit_code),
        Err(error) => {
            let _ = writeln!(
                io::stderr().lock(),
                "Could not write command response: {error}. The command may already have completed; inspect the budget before retrying a mutation."
            );
            ExitCode::from(6)
        }
    }
}

fn main() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error) => match error.kind() {
            clap::error::ErrorKind::DisplayHelp | clap::error::ErrorKind::DisplayVersion => {
                let _ = error.print();
                return ExitCode::SUCCESS;
            }
            _ => {
                let message = error.to_string();
                let envelope = bw_cli::error_envelope("arguments", usage_error(message.clone()));
                let _ = writeln!(io::stderr().lock(), "{message}");
                return emit_response(
                    &serde_json::to_string(&envelope).unwrap_or_else(|_| "{}".to_string()),
                    2,
                );
            }
        },
    };

    let output_format = cli.output;
    let currency = if output_format == bw_cli::OutputFormat::Text {
        bw_cli::config::load(cli.config_dir.as_deref())
            .ok()
            .and_then(|config| config.currency)
    } else {
        None
    };
    let result = dispatch(cli);
    match result {
        Ok(outcome) => {
            let line = if output_format == bw_cli::OutputFormat::Text {
                bw_cli::render_text(&outcome, currency.as_deref())
            } else {
                serde_json::to_string(&outcome.envelope).unwrap_or_else(|_| "{}".to_string())
            };
            emit_response(&line, 0)
        }
        Err((command, error)) => {
            let line = if output_format == bw_cli::OutputFormat::Text {
                error.message.clone()
            } else {
                let envelope = bw_cli::error_envelope(&command, error.clone());
                serde_json::to_string(&envelope).unwrap_or_else(|_| "{}".to_string())
            };
            if !error.message.is_empty() {
                let _ = writeln!(io::stderr().lock(), "{}", error.message);
            }
            emit_response(&line, error.exit_code)
        }
    }
}
