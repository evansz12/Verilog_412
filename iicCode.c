#include <stdio.h>
#include <string.h>
#include <ctype.h>

/*************************************************************
** IIC Controller registers
**************************************************************/
// IIC Registers
#define ClockPrescale_l         (*(volatile unsigned char *)(0x00408000))   //8 bits each
#define ClockPrescale_h          (*(volatile unsigned char *)(0x00408002))
#define Control_Reg            (*(volatile unsigned char *)(0x00408004))
#define TXRX_Reg             (*(volatile unsigned char *)(0x00408006))
#define ComSta_Reg              (*(volatile unsigned char *)(0x00408008))

#define RS232_Control     *(volatile unsigned char *)(0x00400040)
#define RS232_Status      *(volatile unsigned char *)(0x00400040)
#define RS232_TxData      *(volatile unsigned char *)(0x00400042)
#define RS232_RxData      *(volatile unsigned char *)(0x00400042)
#define RS232_Baud        *(volatile unsigned char *)(0x00400044)


int _putch(int c)
{
	while (((char)(RS232_Status) & (char)(0x02)) != (char)(0x02))    // wait for Tx bit in status register or 6850 serial comms chip to be '1'
		;

	(char)(RS232_TxData) = ((char)(c) & (char)(0x7f));                      // write to the data register to output the character (mask off bit 8 to keep it 7 bit ASCII)
	return c;                                              // putchar() expects the character to be returned
}

int _getch(void)
{
	int c;
	while (((char)(RS232_Status) & (char)(0x01)) != (char)(0x01))    // wait for Rx bit in 6850 serial comms chip status register to be '1'
		;

	c = (RS232_RxData & (char)(0x7f));                   // read received character, mask off top bit and return as 7 bit ASCII character

	_putch(c);

	return c;
}

char xtod(int c)
{
	if ((char)(c) <= (char)('9'))
		return c - (char)(0x30);    // 0 - 9 = 0x30 - 0x39 so convert to number by sutracting 0x30
	else if ((char)(c) > (char)('F'))    // assume lower case
		return c - (char)(0x57);    // a-f = 0x61-66 so needs to be converted to 0x0A - 0x0F so subtract 0x57
	else
		return c - (char)(0x37);    // A-F = 0x41-46 so needs to be converted to 0x0A - 0x0F so subtract 0x37
}

int Get2HexDigits(char *CheckSumPtr)
{
    register int i = (xtod(_getch()) << 4) | (xtod(_getch()));

    if(CheckSumPtr)
        *CheckSumPtr += i ;

    return i ;
}

int Get4HexDigits(char *CheckSumPtr)
{
    return (Get2HexDigits(CheckSumPtr) << 8) | (Get2HexDigits(CheckSumPtr));
}

int Get6HexDigits(char *CheckSumPtr)
{
    return (Get4HexDigits(CheckSumPtr) << 8) | (Get2HexDigits(CheckSumPtr));
}

void IIC_Init(void)
{
	ClockPrescale_l = 0x4F; //40MHz
	ClockPrescale_h = 0x00;
	Control_Reg = 0x80;
}

void byteWrite(unsigned int i, unsigned int addr, unsigned int data)
{
    unsigned int blockN;
    if (i == (char)('0')) {blockN = 0xA0;} //slave addr: 1010_000 + W: 0, block 0
    else {blockN = 0xA8;}        //slave addr: 1010_100 + W: 0, block 1

    //specify slave addr
    TXRX_Reg = blockN;
    ComSta_Reg = 0x90;  //STA, WR bit
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}  //wait for ACK & TIP bit to be 0

    //specify addr
    TXRX_Reg = (addr & 0xFF00) / 0x100;
    ComSta_Reg = 0x10;  //WR bit
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

    TXRX_Reg = addr & 0xFF;
    ComSta_Reg = 0x10;  //WR bit
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

    //write data
    TXRX_Reg = data;
    ComSta_Reg = 0x50;  //STOP, WR bit
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

    //polling
    TXRX_Reg = blockN;
    ComSta_Reg = 0x90;

    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {
        TXRX_Reg = blockN;
        ComSta_Reg = 0x90;
    }
    TXRX_Reg = blockN;
    ComSta_Reg = 0x18;
    printf("\nWrite to 0x%c%04x: %02x", i, addr, data);
}

void byteRead(char i, unsigned int addr)
{
    unsigned int c, blockN, blockRN;
    if (i == (char)('0')) {blockN = 0xA0; blockRN = 0xA1;} //slave addr: 1010_000 + W: 0, block 0
    else {blockN = 0xA8; blockRN = 0xA9;}        //slave addr: 1010_100 + W: 0, block 1
    printf("\n%x %x", addr / 256, addr % 256);
    //specify slave addr
    TXRX_Reg = blockN;
    ComSta_Reg = 0x90;  //STA, WR bit
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

    //specify addr
    TXRX_Reg = (addr & 0xFF00) / 0x100;
    ComSta_Reg = 0x10;  //WR bit
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

    TXRX_Reg = addr & 0xFF;
    ComSta_Reg = 0x10;  //WR bit
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

    //read data
    TXRX_Reg = blockRN;
    ComSta_Reg = 0x90;  //START, WR bit
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

    TXRX_Reg = blockRN;
    ComSta_Reg = 0x20;
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

    c = TXRX_Reg;
    printf("\nRead 0x%c%04x: %02x", i, addr, c);

    TXRX_Reg = blockN;
    ComSta_Reg = 0x08;
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

    TXRX_Reg = blockN;
    ComSta_Reg = 0x40;  //STO, WR bit
    while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

}

void callPageWrite(unsigned int i, unsigned int addr, unsigned int size, unsigned int fill)
{
    if (addr < 0x10000 && addr + size > 0x10000) {
        pageWrite('0', addr, 0x10000 - addr, fill);
        pageWrite('1', 0, size - 0x10000 + addr, fill);
    }
    else {
        pageWrite(i, addr, size, fill);
    }
}
void pageWrite(unsigned int i, unsigned int addr, unsigned int size, unsigned int fill)
{
    unsigned int j, flag, blockN, addrRem, sizeRem, rem;
    if (i == (char)('0')) {blockN = 0xA0;} //slave addr: 1010_000 + W: 0, block 0
    else {blockN = 0xA8;}        //slave addr: 1010_100 + W: 0, block 1

//n blocks
    flag = 1;
    j = addr;
    while (flag) {
        TXRX_Reg = blockN;
        ComSta_Reg = 0x90;  //STA, WR bit
        while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}  //wait for ACK & TIP bit to be 0

        //specify addr
        TXRX_Reg = (j & 0xFF00) / 0x100;
        ComSta_Reg = 0x10;  //WR bit
        while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}
        TXRX_Reg = j & 0xFF;
        ComSta_Reg = 0x10;  //WR bit
        while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

        for (j; (j % 128) < 127; j++) {   //loops until 2nd last bit
            TXRX_Reg = fill;
            ComSta_Reg = 0x10;  //WR bit
            while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}
        }
        TXRX_Reg = fill;        //final for sending STOP
        ComSta_Reg = 0x50;  //STOP, WR bit
        while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}
        //polling
        TXRX_Reg = blockN;
        ComSta_Reg = 0x90;
        while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {
            TXRX_Reg = blockN;
            ComSta_Reg = 0x90;
        }
        TXRX_Reg = blockN;
        ComSta_Reg = 0x18;
        j++;
        if ((size - (j - addr)) / 128 == 0) {
            flag = 0;
        }
    }

//last block
    rem = (size - (j - addr)) % 128;
    printf("\n%x %x", rem, j);
    if (rem > 0) {
        TXRX_Reg = blockN;
        ComSta_Reg = 0x90;  //STA, WR bit
        while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}  //wait for ACK & TIP bit to be 0

        //specify addr
        TXRX_Reg = (j & 0xFF00) / 0x100;
        ComSta_Reg = 0x10;  //WR bit
        while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}
        TXRX_Reg = j & 0xFF;
        ComSta_Reg = 0x10;  //WR bit
        while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}

        for (j= 0; j < rem; j++) {   //loops until 2nd last bit
            TXRX_Reg = fill;
            ComSta_Reg = 0x10;  //WR bit
            while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}
        }
        TXRX_Reg = fill;        //final for sending STOP
        ComSta_Reg = 0x50;  //STOP, WR bit
        while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {}
        //polling
        TXRX_Reg = blockN;
        ComSta_Reg = 0x90;
        while ((ComSta_Reg & (char)(0x82)) != (char)(0x00)) {
            TXRX_Reg = blockN;
            ComSta_Reg = 0x90;
        }
        TXRX_Reg = blockN;
        ComSta_Reg = 0x18;
    }
}

void main(void)
{
    unsigned char i;
    unsigned int addr, data, size, fill;

    IIC_Init();
    while (1) {
        printf("\n0: Write single byte");
        printf("\n1: Read single byte");
        printf("\n2: Write pages");
        i = _getch();
        if (i == (char)('0')) {
            printf("\nWrite to block 0 or 1: ");
            i = _getch();
            printf("\nHex address: ");
            addr = Get4HexDigits(0);
            printf("\nData: ");
            data = Get2HexDigits(0);
            byteWrite(i, addr, data);
        }
        else if (i == (char)('1')) {
            printf("\nRead block 0 or 1: ");
            i = _getch();
            printf("\nHex address: ");
            addr = Get4HexDigits(0);
            byteRead(i, addr);
        }
        else if (i == (char)('2')) {
            printf("\nStart at block 0 or 1: ");
            i = _getch();
            printf("\nStart hex address: ");
            addr = Get4HexDigits(0);
            printf("\nHow many bytes (6 hex digits): ");
            size = Get6HexDigits(0);
            printf("\nFill with: ");
            fill = Get2HexDigits(0);
            callPageWrite(i, addr, size, fill);
        }
    }
}