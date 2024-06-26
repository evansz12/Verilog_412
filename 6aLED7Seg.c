#include <stdio.h>
#include <Bios.h>
#include <ucos_ii.h>

#define STACKSIZE  256

#define RS232_Status      *(volatile unsigned char *)(0x00400040)
#define RS232_TxData      *(volatile unsigned char *)(0x00400042)
#define RS232_RxData      *(volatile unsigned char *)(0x00400042)

/*
** Stacks for each task are allocated here in the application in this case = 256 bytes
** but you can change size if required
*/

OS_STK Task1Stk[STACKSIZE];
OS_STK Task2Stk[STACKSIZE];
OS_STK Task3Stk[STACKSIZE];
OS_STK Task4Stk[STACKSIZE];


/*********************************************************************************************
**	Hex 7 seg displays port addresses
*********************************************************************************************/

#define HEX_A        *(volatile unsigned char *)(0x00400010)
#define HEX_B        *(volatile unsigned char *)(0x00400012)
#define HEX_D        *(volatile unsigned char *)(0x00400016)    // de2 only

/* Prototypes for our tasks/threads*/
void Task1(void *);    /* (void *) means the child task expects no data from parent*/
void Task2(void *);
void Task3(void *);
void Task4(void *);

/*
** Our main application which has to
** 1) Initialise any peripherals on the board, e.g. RS232 for hyperterminal + LCD
** 2) Call OSInit() to initialise the OS
** 3) Create our application task/threads
** 4) Call OSStart()
*/

void main(void)
{
    // initialise board hardware by calling our routines from the BIOS.C source file

    Init_RS232();

    OSInit();        // call to initialise the OS

/*
** Now create the 4 child tasks and pass them no data.
** the smaller the numerical priority value, the higher the task priority
*/

    OSTaskCreate(Task1, OS_NULL, &Task1Stk[STACKSIZE], 12);
    OSTaskCreate(Task2, OS_NULL, &Task2Stk[STACKSIZE], 11);     // highest priority task

    OSStart();  // call to start the OS scheduler, (never returns from this function)
}

/*
** IMPORTANT : Timer 1 interrupts must be started by the highest priority task
** that runs first which is Task2
*/

void Task1(void *pdata)
{
    int delay ;
    unsigned char count = 0 ;

    for (;;) {
        PortA = PortB = PortC = PortD = ((count << 4) + (count & 0x0f)) ;
        OSTimeDly(230);
        count ++;
    }
}

/*
** Task 2 below was created with the highest priority so it must start timer1
** so that it produces interrupts for the 100hz context switches
*/

void Task2(void *pdata)
{
    int delay ;
    unsigned char count = 0 ;
    char frameId[2], data[8];

    // must start timer ticker here

    Timer1_Init() ;      // this function is in BIOS.C and written by us to start timer


    for (;;) {
        HEX_A = HEX_B = HEX_C = HEX_D = ((count << 4) + (count & 0x0f)) ;
        OSTimeDly(70);
        count ++;
    }
}