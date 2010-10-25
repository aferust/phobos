/**
 * Implementation of exception handling support routines for Posix.
 *
 * Copyright: Copyright Digital Mars 2000 - 2010.
 * License:
 * Distributed under the Boost Software License, Version 1.0.
 *    (See accompanying file LICENSE_1_0.txt or copy at
 *          $(LINK http://www.boost.org/LICENSE_1_0.txt))
 * Authors:   Walter Bright
 */

/* deh.c is Windows only. It is in C because it interacts with all the complex Windows header
 * definitions for Windows SEH that have not been ported to D. D's eh mechanism on Windows is
 * layered on top of Windows SEH.
 *
 * For other platforms, deh2.d is used instead, as D uses its own invented exception handling
 * mechanism. (It is not compatible with the C++ eh ELF mechanism.)
 */

//debug=1;

import std.c.linux.linuxextern;

extern (C) int _d_isbaseof(ClassInfo oc, ClassInfo c);

alias int (*fp_t)();   // function pointer in ambient memory model

// DHandlerInfo table is generated by except_gentables() in eh.c

struct DHandlerInfo
{
    uint offset;                // offset from function address to start of guarded section
    uint endoffset;             // offset of end of guarded section
    int prev_index;             // previous table index
    uint cioffset;              // offset to DCatchInfo data from start of table (!=0 if try-catch)
    void *finally_code;         // pointer to finally code to execute
                                // (!=0 if try-finally)
}

// Address of DHandlerTable, searched for by eh_finddata()

struct DHandlerTable
{
    void *fptr;                 // pointer to start of function
    uint espoffset;             // offset of ESP from EBP
    uint retoffset;             // offset from start of function to return code
    size_t nhandlers;           // dimension of handler_info[] (use size_t to set alignment of handler_info[])
    DHandlerInfo handler_info[1];
}

struct DCatchBlock
{
    ClassInfo type;             // catch type
    size_t bpoffset;            // EBP offset of catch var
    void *code;                 // catch handler code
}

// Create one of these for each try-catch
struct DCatchInfo
{
    size_t ncatches;                    // number of catch blocks
    DCatchBlock catch_block[1];         // data for each catch block
}

// One of these is generated for each function with try-catch or try-finally

struct FuncTable
{
    void *fptr;                 // pointer to start of function
    DHandlerTable *handlertable; // eh data for this function
    uint fsize;         // size of function in bytes
}

void terminate()
{
    asm
    {
        hlt ;
    }
}

/*******************************************
 * Given address that is inside a function,
 * figure out which function it is in.
 * Return DHandlerTable if there is one, NULL if not.
 */

DHandlerTable *__eh_finddata(void *address)
{
    debug printf("FuncTable.sizeof = %p\n", FuncTable.sizeof);
    debug printf("__eh_finddata(address = %p)\n", address);
    debug printf("_deh_beg = %p, _deh_end = %p\n", &_deh_beg, &_deh_end);
    for (auto ft = cast(FuncTable *)&_deh_beg;
         ft < cast(FuncTable *)&_deh_end;
         ft++)
    {
      debug printf("\tft = %p, fptr = %p, fsize = x%03x, handlertable = %p\n",
              ft, ft.fptr, ft.fsize, ft.handlertable);

        if (ft.fptr <= address &&
            address < cast(void *)(cast(char *)ft.fptr + ft.fsize))
        {
          debug printf("\tfound handler table\n");
            return ft.handlertable;
        }
    }
    debug printf("\tnot found\n");
    return null;
}


/******************************
 * Given EBP, find return address to caller, and caller's EBP.
 * Input:
 *   regbp       Value of EBP for current function
 *   *pretaddr   Return address
 * Output:
 *   *pretaddr   return address to caller
 * Returns:
 *   caller's EBP
 */

size_t __eh_find_caller(size_t regbp, size_t *pretaddr)
{
    size_t bp = *cast(size_t *)regbp;

    if (bp)         // if not end of call chain
    {
        // Perform sanity checks on new EBP.
        // If it is screwed up, terminate() hopefully before we do more damage.
        if (bp <= regbp)
            // stack should grow to smaller values
            terminate();

        *pretaddr = *cast(size_t *)(regbp + size_t.sizeof);
    }
    return bp;
}

/***********************************
 * Deprecated because of Bugzilla 4398,
 * keep for the moment for backwards compatibility.
 */

extern (Windows) void _d_throw(Object *h)
{
    _d_throwc(h);
}

/***********************************
 * Throw a D object.
 */

extern (C) void _d_throwc(Object *h)
{
    size_t regebp;

    debug
    {
        printf("_d_throw(h = %p, &h = %p)\n", h, &h);
        printf("\tvptr = %p\n", *cast(void **)h);
    }

    version (D_InlineAsm_X86)
        asm
        {
            mov regebp,EBP  ;
        }
    else version (D_InlineAsm_X86_64)
        asm
        {
            mov regebp,RBP  ;
        }
    else
        static assert(0);

//static uint abc;
//if (++abc == 2) *(char *)0=0;

//int count = 0;
    while (1)           // for each function on the stack
    {
        size_t retaddr;

        regebp = __eh_find_caller(regebp,&retaddr);
        if (!regebp)
        {   // if end of call chain
            debug printf("end of call chain\n");
            break;
        }

        debug printf("found caller, EBP = %p, retaddr = %p\n", regebp, retaddr);
//if (++count == 12) *(char*)0=0;
        auto handler_table = __eh_finddata(cast(void *)retaddr);   // find static data associated with function
        if (!handler_table)         // if no static data
        {
            debug printf("no handler table\n");
            continue;
        }
        auto funcoffset = cast(size_t)handler_table.fptr;
        auto spoff = handler_table.espoffset;
        auto retoffset = handler_table.retoffset;

        debug
        {
            printf("retaddr = %p\n", retaddr);
            printf("regebp=%p, funcoffset=%p, spoff=x%x, retoffset=x%x\n",
            regebp,funcoffset,spoff,retoffset);
        }

        // Find start index for retaddr in static data
        auto dim = handler_table.nhandlers;

        debug
        {
            printf("handler_info[%d]:\n", dim);
            for (int i = 0; i < dim; i++)
            {
                auto phi = &handler_table.handler_info[i];
                printf("\t[%d]: offset = x%04x, endoffset = x%04x, prev_index = %d, cioffset = x%04x, finally_code = %x\n",
                        i, phi.offset, phi.endoffset, phi.prev_index, phi.cioffset, phi.finally_code);
            }
        }

        auto index = -1;
        for (int i = 0; i < dim; i++)
        {
            auto phi = &handler_table.handler_info[i];

            debug printf("i = %d, phi.offset = %04x\n", i, funcoffset + phi.offset);
            if (retaddr > funcoffset + phi.offset &&
                retaddr <= funcoffset + phi.endoffset)
                index = i;
        }
        debug printf("index = %d\n", index);

        // walk through handler table, checking each handler
        // with an index smaller than the current table_index
        int prev_ndx;
        for (auto ndx = index; ndx != -1; ndx = prev_ndx)
        {
            auto phi = &handler_table.handler_info[ndx];
            prev_ndx = phi.prev_index;
            if (phi.cioffset)
            {
                // this is a catch handler (no finally)

                auto pci = cast(DCatchInfo *)(cast(char *)handler_table + phi.cioffset);
                auto ncatches = pci.ncatches;
                for (int i = 0; i < ncatches; i++)
                {
                    auto ci = **cast(ClassInfo **)h;

                    auto pcb = &pci.catch_block[i];

                    if (_d_isbaseof(ci, pcb.type))
                    {   // Matched the catch type, so we've found the handler.

                        // Initialize catch variable
                        *cast(void **)(regebp + (pcb.bpoffset)) = h;

                        // Jump to catch block. Does not return.
                        {
                            size_t catch_esp;
                            fp_t catch_addr;

                            catch_addr = cast(fp_t)(pcb.code);
                            catch_esp = regebp - handler_table.espoffset - fp_t.sizeof;
                            version (D_InlineAsm_X86)
                                asm
                                {
                                    mov     EAX,catch_esp   ;
                                    mov     ECX,catch_addr  ;
                                    mov     [EAX],ECX       ;
                                    mov     EBP,regebp      ;
                                    mov     ESP,EAX         ; // reset stack
                                    ret                     ; // jump to catch block
                                }
                            else version (D_InlineAsm_X86_64)
                                asm
                                {
                                    mov     RAX,catch_esp   ;
                                    mov     RCX,catch_esp   ;
                                    mov     RCX,catch_addr  ;
                                    mov     [RAX],RCX       ;
                                    mov     RBP,regebp      ;
                                    mov     RSP,RAX         ; // reset stack
                                    ret                     ; // jump to catch block
                                }
                            else
                                static assert(0);
                        }
                    }
                }
            }
            else if (phi.finally_code)
            {   // Call finally block
                // Note that it is unnecessary to adjust the ESP, as the finally block
                // accesses all items on the stack as relative to EBP.

                auto blockaddr = phi.finally_code;

                version (OSX)
                {
                    version (D_InlineAsm_X86)
                        asm
                        {
                            sub     ESP,4           ;
                            push    EBX             ;
                            mov     EBX,blockaddr   ;
                            push    EBP             ;
                            mov     EBP,regebp      ;
                            call    EBX             ;
                            pop     EBP             ;
                            pop     EBX             ;
                            add     ESP,4           ;
                        }
                    else version (D_InlineAsm_X86_64)
                        asm
                        {
                            sub     RSP,8           ;
                            push    RBX             ;
                            mov     RBX,blockaddr   ;
                            push    RBP             ;
                            mov     RBP,regebp      ;
                            call    RBX             ;
                            pop     RBP             ;
                            pop     RBX             ;
                            add     RSP,8           ;
                        }
                    else
                        static assert(0);
                }
                else
                {
                    version (D_InlineAsm_X86)
                        asm
                        {
                            push    EBX             ;
                            mov     EBX,blockaddr   ;
                            push    EBP             ;
                            mov     EBP,regebp      ;
                            call    EBX             ;
                            pop     EBP             ;
                            pop     EBX             ;
                        }
                    else version (D_InlineAsm_X86_64)
                        asm
                        {
                            sub     RSP,8           ;
                            push    RBX             ;
                            mov     RBX,blockaddr   ;
                            push    RBP             ;
                            mov     RBP,regebp      ;
                            call    RBX             ;
                            pop     RBP             ;
                            pop     RBX             ;
                            add     RSP,8           ;
                        }
                    else
                        static assert(0);
                }
            }
        }
    }
}
