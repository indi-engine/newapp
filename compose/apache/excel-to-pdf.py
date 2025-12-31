

import uno, os, sys, subprocess, time
from com.sun.star.beans import PropertyValue

# Prepare a file url from a system path
def url(path): return uno.systemPathToFileUrl(os.path.abspath(path))

# Define UNO socket and other shortcuts
socket = "socket,host=127.0.0.1,port=2002;urp;"
proc = None
doc = None

# Try our best
try:

    # Open libreoffice subprocess
    proc = subprocess.Popen([
        "libreoffice", "--headless", "--nologo", "--nodefault", "--nolockcheck", "--nofirststartwizard", "--norestore",
        "--invisible", "-env:SAL_USE_VCLPLUGIN=svp", f"--accept={socket}"
    ])

    # Connect to LibreOffice
    local = uno.getComponentContext()
    resolver = local.ServiceManager.createInstanceWithContext("com.sun.star.bridge.UnoUrlResolver", local)
    for _ in range(20):
        try:
            context = resolver.resolve(f"uno:{socket}StarOffice.ComponentContext")
            if context: break
        except Exception:
            time.sleep(0.5)
    else:
        raise RuntimeError("Could not connect to LibreOffice")

    window = context.ServiceManager.createInstanceWithContext("com.sun.star.frame.Desktop", context)

    # Open document and get styles
    doc = window.loadComponentFromURL(url(sys.argv[1]), "_blank", 0, (PropertyValue("Hidden", 0, True, 0),))
    styles = doc.getStyleFamilies().getByName("PageStyles")

    # Foreach sheet
    for i in range(doc.getSheets().getCount()):

        # Get current sheet
        sheet = doc.getSheets().getByIndex(i)

        # Calc width usage
        cursor = sheet.createCursor()
        cursor.gotoEndOfUsedArea(True)
        width_usage = sum(sheet.getColumns().getByIndex(c).Width for c in range(cursor.RangeAddress.EndColumn + 1))

        # Create page style for the current sheet
        style_name = f"Sheet_{i}"
        styles.insertByName(style_name, doc.createInstance("com.sun.star.style.PageStyle"))
        sheet.PageStyle = style_name
        style = styles.getByName(style_name)

        # Apply sizing and layout
        style.LeftMargin = style.RightMargin = style.TopMargin = style.BottomMargin = 500
        style.Width = width_usage + style.LeftMargin + style.RightMargin
        style.Height = 21000
        style.IsLandscape = style.Width > style.Height
        style.ScaleToPagesX = 1
        style.ScaleToPagesY = 0
        style.PrintGrid = True

        # Show sheet number and name
        header = style.RightPageHeaderContent
        header.LeftText.setString(f"Sheet #{i + 1}")
        header.CenterText.setString(sheet.Name)

        # Show page number within a sheet
        cursor = header.RightText.createTextCursor()
        header.RightText.insertString(cursor, "Page ", False)
        header.RightText.insertTextContent(cursor, doc.createInstance("com.sun.star.text.TextField.PageNumber"), False)

        # Apply header to style
        style.HeaderIsOn = True
        style.RightPageHeaderContent = header
        style.HeaderBodyDistance = style.TopMargin
        style.HeaderHeight = 800

    # Save as PDF
    doc.storeToURL(url(sys.argv[2]), (PropertyValue("FilterName", 0, "calc_pdf_Export", 0),))

# Finalize
finally:

    # Close document if opened
    if doc:
        try:
            doc.close(True)
        except Exception:
            pass

    # Shutdown LibreOffice
    try:
        if 'window' in locals():
            window.terminate()
    except Exception:
        pass

    # Hard kill subprocess as last resort
    if proc:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()