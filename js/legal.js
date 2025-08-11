/**
 * TRODDR Legal Pages JavaScript
 * Handles interactive functionality for legal pages (Terms, Privacy Policy, etc.)
 */

document.addEventListener('DOMContentLoaded', function() {
    // Initialize all legal page functionality
    initBackToTop();
    initSmoothScrolling();
    initTableOfContents();
    initPrintFunctionality();
    
    // Add legal-page class to body for specific styling
    document.body.classList.add('legal-page');
});

/**
 * Back to Top Button Functionality
 */
function initBackToTop() {
    const backToTop = document.getElementById('backToTop');
    
    if (!backToTop) return;
    
    // Show/hide button based on scroll position
    window.addEventListener('scroll', function() {
        if (window.pageYOffset > 300) {
            backToTop.classList.add('visible');
        } else {
            backToTop.classList.remove('visible');
        }
    });

    // Smooth scroll to top when clicked
    backToTop.addEventListener('click', function(e) {
        e.preventDefault();
        window.scrollTo({ 
            top: 0, 
            behavior: 'smooth' 
        });
    });
}

/**
 * Smooth Scrolling for Table of Contents Links
 */
function initSmoothScrolling() {
    // Handle TOC links
    const tocLinks = document.querySelectorAll('.legal-toc a[href^="#"]');
    
    tocLinks.forEach(link => {
        link.addEventListener('click', function(e) {
            e.preventDefault();
            
            const targetId = this.getAttribute('href').substring(1);
            const targetElement = document.getElementById(targetId);
            
            if (targetElement) {
                const headerOffset = 120; // Account for fixed header
                const elementPosition = targetElement.getBoundingClientRect().top;
                const offsetPosition = elementPosition + window.pageYOffset - headerOffset;
                
                window.scrollTo({
                    top: offsetPosition,
                    behavior: 'smooth'
                });
                
                // Add visual feedback
                targetElement.style.scrollMarginTop = headerOffset + 'px';
                
                // Optional: Add a brief highlight effect
                highlightSection(targetElement);
            }
        });
    });
}

/**
 * Table of Contents Active State Management
 */
function initTableOfContents() {
    const sections = document.querySelectorAll('.legal-section');
    const tocLinks = document.querySelectorAll('.legal-toc a');
    
    if (sections.length === 0 || tocLinks.length === 0) return;
    
    // Create intersection observer for active section highlighting
    const observerOptions = {
        root: null,
        rootMargin: '-120px 0px -50% 0px', // Account for header height
        threshold: 0.1
    };
    
    const observer = new IntersectionObserver(function(entries) {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                const activeId = entry.target.id;
                updateActiveTocLink(activeId);
            }
        });
    }, observerOptions);
    
    // Observe all sections
    sections.forEach(section => {
        observer.observe(section);
    });
}

/**
 * Update active state in table of contents
 */
function updateActiveTocLink(activeId) {
    const tocLinks = document.querySelectorAll('.legal-toc a');
    
    tocLinks.forEach(link => {
        link.classList.remove('active');
        
        if (link.getAttribute('href') === '#' + activeId) {
            link.classList.add('active');
        }
    });
}

/**
 * Highlight section when navigated to
 */
function highlightSection(element) {
    // Remove any existing highlights
    document.querySelectorAll('.legal-section.highlighted').forEach(el => {
        el.classList.remove('highlighted');
    });
    
    // Add highlight class
    element.classList.add('highlighted');
    
    // Remove highlight after animation
    setTimeout(() => {
        element.classList.remove('highlighted');
    }, 2000);
}

/**
 * Print Functionality
 */
function initPrintFunctionality() {
    // Add print styles optimization
    window.addEventListener('beforeprint', function() {
        // Collapse any open mobile menus
        document.body.classList.add('printing');
    });
    
    window.addEventListener('afterprint', function() {
        document.body.classList.remove('printing');
    });
    
    // Optional: Add print button (uncomment if needed)
    /*
    const printButton = document.createElement('button');
    printButton.textContent = 'Print';
    printButton.className = 'print-button';
    printButton.addEventListener('click', () => window.print());
    
    const container = document.querySelector('.legal-container');
    if (container) {
        container.appendChild(printButton);
    }
    */
}

/**
 * Keyboard Navigation Enhancement
 */
document.addEventListener('keydown', function(e) {
    // Press 'T' to go to top
    if (e.key === 't' || e.key === 'T') {
        if (!e.ctrlKey && !e.altKey && !e.metaKey) {
            const activeElement = document.activeElement;
            
            // Only trigger if not typing in an input
            if (activeElement.tagName !== 'INPUT' && 
                activeElement.tagName !== 'TEXTAREA' && 
                !activeElement.isContentEditable) {
                
                e.preventDefault();
                window.scrollTo({ top: 0, behavior: 'smooth' });
            }
        }
    }
});

/**
 * Copy Section Link Functionality
 */
function initCopyLinks() {
    const sectionHeaders = document.querySelectorAll('.legal-section h2');
    
    sectionHeaders.forEach(header => {
        header.style.cursor = 'pointer';
        header.title = 'Click to copy link to this section';
        
        header.addEventListener('click', function() {
            const sectionId = this.parentElement.id;
            const url = window.location.origin + window.location.pathname + '#' + sectionId;
            
            // Copy to clipboard if available
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(url).then(() => {
                    showCopyFeedback(this);
                }).catch(err => {
                    console.log('Could not copy text: ', err);
                });
            } else {
                // Fallback for older browsers
                const textArea = document.createElement('textarea');
                textArea.value = url;
                document.body.appendChild(textArea);
                textArea.focus();
                textArea.select();
                
                try {
                    document.execCommand('copy');
                    showCopyFeedback(this);
                } catch (err) {
                    console.log('Fallback copy failed: ', err);
                }
                
                document.body.removeChild(textArea);
            }
        });
    });
}

/**
 * Show visual feedback when link is copied
 */
function showCopyFeedback(element) {
    const originalText = element.textContent;
    element.textContent = originalText + ' (Link copied!)';
    element.style.color = 'var(--green)';
    
    setTimeout(() => {
        element.textContent = originalText;
        element.style.color = '';
    }, 2000);
}

/**
 * Reading Progress Indicator
 */
function initReadingProgress() {
    const progressBar = document.createElement('div');
    progressBar.className = 'reading-progress';
    progressBar.innerHTML = '<div class="reading-progress-bar"></div>';
    
    // Add to body
    document.body.appendChild(progressBar);
    
    const progressBarFill = progressBar.querySelector('.reading-progress-bar');
    
    window.addEventListener('scroll', function() {
        const windowHeight = window.innerHeight;
        const documentHeight = document.documentElement.scrollHeight - windowHeight;
        const scrollTop = window.pageYOffset;
        const progress = (scrollTop / documentHeight) * 100;
        
        progressBarFill.style.width = Math.min(progress, 100) + '%';
    });
}

/**
 * Add CSS for reading progress (if enabled)
 */
function addProgressBarStyles() {
    const style = document.createElement('style');
    style.textContent = `
        .reading-progress {
            position: fixed;
            top: 0;
            left: 0;
            right: 0;
            height: 3px;
            background: rgba(0, 0, 0, 0.1);
            z-index: 9999;
        }
        
        .reading-progress-bar {
            height: 100%;
            background: linear-gradient(135deg, var(--primary), var(--primary-light));
            transition: width 0.3s ease;
            width: 0%;
        }
        
        @media print {
            .reading-progress {
                display: none !important;
            }
        }
    `;
    document.head.appendChild(style);
}

/**
 * Mobile Menu Toggle (if nav links are hidden on mobile)
 */
function initMobileMenu() {
    const navbar = document.querySelector('.navbar');
    const navLinks = document.querySelector('.nav-links');
    
    if (!navbar || !navLinks) return;
    
    // Create mobile menu button
    const mobileMenuBtn = document.createElement('button');
    mobileMenuBtn.className = 'mobile-menu-btn';
    mobileMenuBtn.innerHTML = '☰';
    mobileMenuBtn.setAttribute('aria-label', 'Toggle navigation menu');
    
    // Insert before nav-links
    navbar.insertBefore(mobileMenuBtn, navLinks);
    
    // Toggle menu
    mobileMenuBtn.addEventListener('click', function() {
        navLinks.classList.toggle('mobile-open');
        mobileMenuBtn.classList.toggle('active');
        
        // Update aria-label
        const isOpen = navLinks.classList.contains('mobile-open');
        mobileMenuBtn.setAttribute('aria-label', isOpen ? 'Close navigation menu' : 'Open navigation menu');
    });
    
    // Close menu when clicking outside
    document.addEventListener('click', function(e) {
        if (!navbar.contains(e.target)) {
            navLinks.classList.remove('mobile-open');
            mobileMenuBtn.classList.remove('active');
        }
    });
    
    // Close menu on escape key
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape') {
            navLinks.classList.remove('mobile-open');
            mobileMenuBtn.classList.remove('active');
        }
    });
}

/**
 * Accessibility Enhancements
 */
function initAccessibility() {
    // Add skip to content link
    const skipLink = document.createElement('a');
    skipLink.href = '#main-content';
    skipLink.textContent = 'Skip to main content';
    skipLink.className = 'skip-link';
    
    // Insert at beginning of body
    document.body.insertBefore(skipLink, document.body.firstChild);
    
    // Add main content ID if not present
    const legalContainer = document.querySelector('.legal-container');
    if (legalContainer && !legalContainer.id) {
        legalContainer.id = 'main-content';
    }
    
    // Add focus management for TOC links
    const tocLinks = document.querySelectorAll('.legal-toc a');
    tocLinks.forEach(link => {
        link.addEventListener('focus', function() {
            this.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        });
    });
}

/**
 * Add skip link styles
 */
function addSkipLinkStyles() {
    const style = document.createElement('style');
    style.textContent = `
        .skip-link {
            position: absolute;
            top: -40px;
            left: 6px;
            background: var(--dark);
            color: white;
            padding: 8px;
            text-decoration: none;
            border-radius: 4px;
            z-index: 10000;
            font-weight: 600;
        }
        
        .skip-link:focus {
            top: 6px;
        }
        
        @media print {
            .skip-link {
                display: none !important;
            }
        }
    `;
    document.head.appendChild(style);
}

/**
 * Initialize all optional features
 * Uncomment the features you want to enable
 */
function initOptionalFeatures() {
    // initCopyLinks();              // Enable section link copying
    // initReadingProgress();        // Enable reading progress bar
    // addProgressBarStyles();       // Add progress bar CSS
    // initMobileMenu();            // Enable mobile menu
    initAccessibility();            // Enable accessibility features
    addSkipLinkStyles();           // Add skip link CSS
}

// Initialize optional features
document.addEventListener('DOMContentLoaded', function() {
    initOptionalFeatures();
});

/**
 * Export functions for external use if needed
 */
window.LegalPageUtils = {
    highlightSection,
    updateActiveTocLink,
    showCopyFeedback
};