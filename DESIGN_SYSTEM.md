# Vault Demo Apps Design System

This document defines the consistent design system for all Vault demo applications, based on HashiCorp Vault's official branding.

## Color Palette

### Primary Colors
- **Background**: `#000000` (Pure Black)
- **Panel Background**: `#1a1a1a` (Dark Gray)
- **Code/Input Background**: `#0a0a0a` (Darker Gray)

### Accent Colors
- **Primary Accent (Vault Yellow)**: `#FFD814`
- **Hover Yellow**: `#FFC700`
- **Yellow Glow**: `rgba(255, 216, 20, 0.1)` - `rgba(255, 216, 20, 0.4)`

### Text Colors
- **Primary Text**: `#FFFFFF` (White)
- **Secondary Text**: `#CCCCCC` (Light Gray)
- **Tertiary Text**: `#888888` (Medium Gray)

### Border Colors
- **Primary Border**: `#333333` (Dark Gray) - Used for default state
- **Hover Border**: `#FFD814` (Yellow) - Used for interactive hover states
- **Disabled**: `#666666`

**Note**: Yellow borders are reserved for hover states only to avoid visual overload. Default borders use subtle gray.

## Typography

### Font Families
```css
/* Primary Font (UI Text) */
font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;

/* Monospace Font (Code/Values) */
font-family: 'SF Mono', 'Monaco', 'Inconsolata', 'Roboto Mono', monospace;
```

### Font Sizes & Weights

#### Headings
- **H1 (Page Title)**: 28px, weight 700, letter-spacing -0.02em, color #FFD814
- **H2 (Section Title)**: 18px, weight 700, letter-spacing -0.01em, color #FFD814
- **H3 (Subsection)**: 16px, weight 600, color #FFD814

#### Body Text
- **Body**: 16px, weight 400, line-height 1.5, color #FFFFFF
- **Small Text**: 14px, weight 400, color #CCCCCC
- **Tiny Text**: 13px, weight 400, color #888888

#### Labels
- **Label**: 12px, weight 600, uppercase, letter-spacing 0.05em, color #FFD814

#### Buttons
- **Button Text**: 15px, weight 600, color #000000

#### Code/Monospace
- **Code Values**: 13-14px, weight 400, line-height 1.6

## Components

### Container
```css
.container {
    max-width: 1000px-1400px; /* Depends on content */
    margin: 0 auto;
    background: #1a1a1a;
    border: 2px solid #333333; /* Gray border by default */
    border-radius: 8px;
    padding: 40px;
}
```

### Header (Title Section)
**Important**: Headers should be separate from content containers and centered.

```css
.header {
    background: #1a1a1a;
    border: 2px solid #333333; /* Gray border, not yellow */
    border-radius: 8px;
    padding: 30px;
    margin-bottom: 20px;
    max-width: 1000px-1400px; /* Match container width */
    margin: 0 auto 20px auto; /* Center the header */
}

.header h1 {
    color: #FFD814;
    font-size: 28px;
    margin-bottom: 10px;
    font-weight: 700;
    letter-spacing: -0.02em;
    text-align: center; /* Always center titles */
}

.header p {
    color: #CCCCCC;
    font-size: 15px;
    font-weight: 400;
    text-align: center; /* Center subtitles */
}
```

### Panel
```css
.panel {
    background: #1a1a1a;
    border: 2px solid #333333; /* Gray border by default */
    padding: 25px;
    border-radius: 8px;
}

.panel:hover {
    border-color: #FFD814; /* Yellow on hover only */
    box-shadow: 0 0 15px rgba(255, 216, 20, 0.1);
}

.panel h2 {
    color: #FFD814;
    font-size: 18px;
    margin-bottom: 20px;
    padding-bottom: 10px;
    border-bottom: 2px solid #FFD814;
    font-weight: 700;
    letter-spacing: -0.01em;
}
```

### Info Box / Card (for displaying data)
**Use for**: Certificate details, credentials, database records, etc.

```css
.info-box {
    background: #0a0a0a;
    border: 2px solid #333333; /* Gray border by default */
    padding: 20px;
    margin: 20px 0;
    border-radius: 6px;
}

.info-box:hover {
    border-color: #FFD814; /* Yellow on hover */
    box-shadow: 0 0 15px rgba(255, 216, 20, 0.1);
}

.info-box .label {
    font-weight: 600;
    color: #FFD814;
    font-size: 12px;
    margin-bottom: 10px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    /* Uses Inter font (inherited from body) */
}

.info-box .value {
    color: #FFFFFF;
    font-family: 'SF Mono', 'Monaco', 'Inconsolata', 'Roboto Mono', monospace;
    font-size: 13px;
    word-break: break-all;
    line-height: 1.6;
    background: #000000;
    padding: 12px;
    border-radius: 4px;
    border: 1px solid #333333;
    font-weight: 400;
}
```

### Result/Feedback Box
**Use for**: Operation results, success/error messages, feedback displays.

```css
.result-box {
    margin-top: 15px;
    padding: 20px;
    background: #000000; /* Pure black */
    border: 2px solid #333333;
    border-radius: 6px;
    min-height: 50px;
    color: #FFFFFF;
    font-family: 'SF Mono', 'Monaco', 'Inconsolata', 'Roboto Mono', monospace;
    font-size: 13px;
    line-height: 1.6;
}

.result-box strong {
    color: #FFD814; /* Yellow for status/emphasis */
    display: block; /* Force line break */
    margin-bottom: 8px;
    font-weight: 600;
}

/* Example usage:
<div class="result-box">
    <strong>Success</strong>
    Record inserted: Your message here
</div>
*/
```

### Buttons
```css
button {
    background: #FFD814;
    color: #000000;
    border: none;
    padding: 12px 24px;
    border-radius: 6px;
    cursor: pointer;
    font-size: 15px;
    font-weight: 600;
    margin: 5px;
    transition: all 0.2s;
    font-family: 'Inter', sans-serif;
}

button:hover {
    background: #FFC700;
    transform: translateY(-1px);
    box-shadow: 0 4px 8px rgba(255, 216, 20, 0.3);
}

button:active {
    transform: translateY(0);
}

button:disabled {
    background: #333333 !important;
    color: #666666 !important;
    cursor: not-allowed !important;
    transform: none !important;
    opacity: 0.5;
}

button:disabled:hover {
    background: #333333 !important;
    transform: none !important;
    box-shadow: none !important;
}
```

### Input Fields
```css
input, textarea {
    width: 100%;
    padding: 12px;
    margin: 8px 0;
    background: #0a0a0a;
    border: 1px solid #333333;
    border-radius: 6px;
    color: #FFFFFF;
    font-size: 14px;
    font-family: 'Inter', sans-serif;
}

input:focus, textarea:focus {
    outline: none;
    border-color: #FFD814;
    box-shadow: 0 0 0 2px rgba(255, 216, 20, 0.1);
}
```

### Status Badge
```css
.status {
    display: inline-block;
    padding: 6px 12px;
    border-radius: 4px;
    font-size: 13px;
    font-weight: 600;
    border: 1px solid #FFD814;
}

.status.active {
    background: rgba(255, 216, 20, 0.1);
    color: #FFD814;
}

.status.inactive {
    background: rgba(136, 136, 136, 0.1);
    color: #888888;
    border-color: #888888;
}
```

### Scrollbar (Webkit)
```css
.scrollable::-webkit-scrollbar {
    width: 8px;
}

.scrollable::-webkit-scrollbar-track {
    background: #0a0a0a;
}

.scrollable::-webkit-scrollbar-thumb {
    background: #FFD814;
    border-radius: 4px;
}

.scrollable::-webkit-scrollbar-thumb:hover {
    background: #FFC700;
}
```

## Layout Patterns

### Grid Layout (2 columns)
```css
.container {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 20px;
    max-width: 1400px;
    margin: 0 auto;
}

.full-width {
    grid-column: 1 / -1;
}
```

### Single Column Layout
```css
.container {
    max-width: 1000px;
    margin: 0 auto;
}
```

## Animations

### Hover Effects
```css
transition: all 0.2s;
```

### Pulse Animation (for rotating/updating elements)
```css
@keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.6; }
}

.rotating {
    animation: pulse 2s infinite;
}
```

## HTML Template Structure

```html
<!DOCTYPE html>
<html>
<head>
    <title>Vault [Feature Name]</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #000000;
            color: #FFFFFF;
            min-height: 100vh;
            padding: 20px;
            font-size: 16px;
            line-height: 1.5;
        }
        /* Add component styles here */
    </style>
</head>
<body>
    <div class="header">
        <h1>🔐 Vault [Feature Name]</h1>
        <p>Brief description of what this demo shows</p>
    </div>
    
    <div class="container">
        <!-- Content panels here -->
    </div>
</body>
</html>
```

## Best Practices

1. **Consistency**: Always use the exact color values defined above
2. **Typography**:
   - Use Inter for UI text (labels, headings, descriptions)
   - Use monospace fonts ONLY for code/values (credentials, certificates, data)
   - Never apply monospace to entire containers
3. **Spacing**: Use consistent padding (12px, 20px, 30px, 40px)
4. **Borders**:
   - Default state: 2px gray (#333333)
   - Hover state: 2px yellow (#FFD814) with subtle glow
   - Never use permanent yellow borders (too visually overwhelming)
5. **Hover States**: Always add yellow border + subtle glow on hover for interactive elements
6. **Accessibility**: Maintain sufficient contrast (white text on black background)
7. **Responsive**: Use max-width containers and flexible layouts
8. **Icons**: Avoid emojis in titles (encoding issues). Use text or SVG icons if needed
9. **Headers**: Always separate from content, center-align titles and subtitles
10. **Font Hierarchy**:
    - Labels use Inter (UI font)
    - Values use SF Mono (monospace)
    - This creates clear visual distinction between labels and data

## Example Usage

When creating a new demo app, copy the HTML template structure and apply the component styles as needed. All demos should feel like part of the same family while serving different purposes.

---

## Common Mistakes to Avoid

1. ❌ **Don't** apply monospace font to entire containers (breaks label readability)
2. ❌ **Don't** use permanent yellow borders (too bright, use gray + yellow hover)
3. ❌ **Don't** use emojis in titles (causes encoding issues in shell scripts)
4. ❌ **Don't** left-align titles (always center for consistency)
5. ❌ **Don't** use black text on white backgrounds (use yellow on black instead)
6. ✅ **Do** use Inter for labels, SF Mono for values
7. ✅ **Do** use gray borders with yellow hover effects
8. ✅ **Do** center all header content
9. ✅ **Do** separate headers from content containers
10. ✅ **Do** use `display: block` on strong tags in result boxes for line breaks

---

**Last Updated**: 2026-05-15
**Version**: 1.1