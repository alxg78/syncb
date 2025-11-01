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
use error::AppError;
use logging::Logger;
use stats::SyncStats;

#[tokio::main]
async fn main() -> Result<()> {
    // Parse command line arguments
    let args = cli::Cli::parse();

    // Initialize configuration
    let config = AppConfig::load(&args).map_err(|e| {
        eprintln!("Error loading configuration: {}", e);
        process::exit(1);
    })?;

    // Initialize logging
    let logger = Logger::init(&config).map_err(|e| {
        eprintln!("Error initializing logger: {}", e);
        process::exit(1);
    })?;

    // Set up signal handlers for graceful shutdown
    setup_signal_handlers();

    // Run the application
    if let Err(e) = run(args, config, logger).await {
        log::error!("Application error: {}", e);
        process::exit(1);
    }

    Ok(())
}

async fn run(args: cli::Cli, config: AppConfig, logger: Logger) -> Result<()> {
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
    let result = sync::perform_sync(&args, &config, &mut stats).await;

    // Show final statistics
    stats.display_summary();

    // Send system notification
    stats.send_notification();

    result
}

fn setup_signal_handlers() {
    // Set up CTRL+C handler for graceful shutdown
    let _ = signal_hook::flag::register(signal_hook::consts::SIGINT, std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)));
}