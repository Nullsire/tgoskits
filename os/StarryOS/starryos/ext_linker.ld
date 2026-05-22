PROVIDE(_ex_table_start = 0);
PROVIDE(_ex_table_end = 0);

SECTIONS {
    .static_keys : {
        __start___static_keys = .;
        KEEP(*(__static_keys))
        __stop___static_keys = .;
    }

    .dyndbg : {
        __start___dyndbg = .;
        KEEP(*(__dyndbg))
        __stop___dyndbg = .;
    }
}

INSERT AFTER .data;