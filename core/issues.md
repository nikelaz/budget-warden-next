# Issues

1. domain.rs:233 moves transactions without recalculating either category's amount_actual
2. domain.rs:405 records reordered ordinals independently. Concurrent reorders can merge into duplicate ordinals, producing unstable ordering because crdt.rs:617 sorts without normalization
