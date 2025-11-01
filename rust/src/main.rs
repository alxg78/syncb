use anyhow::Result;
use clap::Parser;
use std::process;

mod cli;
mod config;
mod crypto;
mod error;
mod lock;
mod logging;
mod stats;
mod sync;

use config::AppConfig;
use logging::Logger;
use stats::SyncStats;


ATENCION, PELIGRO SI SE EJECUTA ESTA VERSION SIN NINGUNA OPCION RELIZA UNA SINCRONIZACION


#[tokio::main]
async fn main() -> Result<()> {
    // Parse command line arguments
    let args = cli::Cli::parse();

    // Initialize configuration
    let config = match AppConfig::load(&args) {
        Ok(config) => config,
        Err(e) => {
            eprintln!("Error loading configuration: {}", e);
            process::exit(1);
        }
    };

    // Initialize logging
    let logger = match Logger::init(&config) {
        Ok(logger) => logger,
        Err(e) => {
            eprintln!("Error initializing logger: {}", e);
            process::exit(1);
        }
    };

    // Set up signal handlers for graceful shutdown
    setup_signal_handlers();

    // Run the application
    if let Err(e) = run(args, config, logger).await {
        log::error!("Application error: {}", e);
        process::exit(1);
    }

    Ok(())
}

async fn run(args: cli::Cli, config: AppConfig, _logger: Logger) -> Result<()> {
    // Show banner
    sync::show_banner(&args, &config);

    // Verify dependencies
    sync::verify_dependencies()?;

    // Set up lock file
    let _lock_guard = lock::LockGuard::acquire(&config)?;

    // Verify preconditions
    sync::verify_preconditions(&config).await?;

    // Confirm execution if needed
    if !args.yes && !args.dry_run {
        sync::confirm_execution()?;
    }

    // Initialize statistics
    let mut stats = SyncStats::new();

    // Perform synchronization
    match sync::perform_sync(&args, &config, &mut stats).await {
        Ok(()) => Ok(()),
        Err(e) => {
            // Convert AppError to anyhow::Error
            Err(anyhow::anyhow!("Sync error: {}", e))
        }
    }
}

fn setup_signal_handlers() {
    // Set up CTRL+C handler for graceful shutdown
    let _ = signal_hook::flag::register(
        signal_hook::consts::SIGINT,
        std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false))
    );
}
