//! App-state rules (spec §4–§7), ported file for file from `Sources/RappCore/StateRules/`.

pub mod detectors;
pub mod engine;
pub mod regions;
pub mod rule_image;
pub mod rule_pack;
pub mod rule_value;
pub mod table;

pub use detectors::{
    foreground_color, shape, text_matches, ShapeName, SignalEvaluator, SignalResult, TextReader, TEXT_EVERY,
};
pub use engine::{compare_versions, AppStateReport, RuleEnv, StateEngine, HEALTH_ROUNDS, REPORT_COUNT_KEYS};
pub use regions::resolve_regions;
pub use rule_image::{color_distance, hsl, Hsl, RuleImage, RuleRect, BLOB_CONTRAST, REGION_CONTRAST};
pub use rule_pack::{
    BlobSpec, BoxSpec, ColorRange, Condition, Detect, EdgeSpec, Length, Pick, RegionRef, RegionSpec, RulePack,
    Side, SignalSpec, SignalStatus, StateRow, StripSpec, VariantSpec,
};
pub use rule_value::{RuleError, RuleValue, RULE_BYTES_LIMIT};
pub use table::{holds, signals_in, StateTable, MAX_SECONDS};
